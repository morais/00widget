import type { CountdownGranularity, Env } from "./types";
import {
  RegisterLiveActivitySchema,
  RegisterLiveActivityStartTokenSchema,
  StartLiveActivitySchema,
  UpdateLiveActivitySchema,
  EndLiveActivitySchema,
  RequestBodyLimits,
} from "./types";
import * as storage from "./storage";
import {
  sendLiveActivityStart,
  sendLiveActivityUpdate,
  sendLiveActivityEnd,
} from "./apns";
import { json, badRequest } from "./http";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";
import { isSharingEnabled, listAcceptedShares } from "./shares";
import { enforceTenantRateLimits, tenantKey, tenantResourceKey } from "./rateLimit";

// The Swift attributes type the iOS app declares. iOS 18+ rejects start
// pushes whose attributes-type doesn't match a registered ActivityAttributes.
const DEFAULT_ATTRIBUTES_TYPE = "ZeroZeroWidgetActivityAttributes";
const APPLE_REFERENCE_DATE_UNIX_SECONDS = 978_307_200;

type ContentStateRecord = Record<string, unknown>;

function activityKitDate(value: string): number {
  return Math.floor(new Date(value).getTime() / 1000) - APPLE_REFERENCE_DATE_UNIX_SECONDS;
}

function initialContentState(
  activity: {
    state: string;
    subtitle?: string;
    icon?: string;
    value?: string;
    unit?: string;
    progress?: number;
    endsAt?: string;
    countdownGranularity?: CountdownGranularity;
    staleAt?: string;
  },
  updatedAt: string,
): ContentStateRecord {
  const state: ContentStateRecord = { state: activity.state, updatedAt };
  if (activity.subtitle !== undefined) state.subtitle = activity.subtitle;
  if (activity.icon !== undefined) state.icon = activity.icon;
  if (activity.value !== undefined) state.value = activity.value;
  if (activity.unit !== undefined) state.unit = activity.unit;
  if (activity.progress !== undefined) state.progress = activity.progress;
  if (activity.endsAt !== undefined) {
    state.endsAt = activity.endsAt;
    state.countdownGranularity = activity.countdownGranularity ?? "second";
  }
  if (activity.staleAt !== undefined) state.staleAt = activity.staleAt;
  return state;
}

function storedContentState(value: unknown): ContentStateRecord {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? { ...(value as ContentStateRecord) }
    : {};
}

function activityKitContentState(state: ContentStateRecord): ContentStateRecord {
  const encoded = { ...state };
  for (const key of ["updatedAt", "endsAt", "staleAt"] as const) {
    const value = encoded[key];
    if (typeof value === "string") encoded[key] = activityKitDate(value);
  }
  return encoded;
}

export async function registerLiveActivity(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req, RequestBodyLimits.registration);
  const parsed = RegisterLiveActivitySchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const limited = await enforceTenantRateLimits(env, auth, [
    { policy: "registrationTenantDay", key: tenantKey(auth.tenantId) },
  ]);
  if (limited) return limited;
  const d = parsed.data;
  const pending = await storage.getPendingActivity(env, auth.tenantId, d.externalActivityId);
  const existing = await storage.getActivityForDevice(
    env,
    auth.tenantId,
    d.externalActivityId,
    d.deviceId,
  );
  const anyExisting = existing ?? await storage.getActivity(env, auth.tenantId, d.externalActivityId);
  await storage.putActivity(env, auth.tenantId, auth.apiKeyHash, d.externalActivityId, {
    pushToken: d.pushToken,
    deviceId: d.deviceId,
    localActivityId: d.localActivityId,
    kind: d.kind,
    updatedAt: new Date().toISOString(),
    lastState: pending
      ? initialContentState(pending, pending.updatedAt)
      : anyExisting?.lastState,
  });
  await storage.deletePendingActivity(env, auth.tenantId, d.externalActivityId);
  return json({ ok: true });
}

export async function registerLiveActivityStartToken(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req, RequestBodyLimits.registration);
  const parsed = RegisterLiveActivityStartTokenSchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const limited = await enforceTenantRateLimits(env, auth, [
    { policy: "registrationTenantDay", key: tenantKey(auth.tenantId) },
  ]);
  if (limited) return limited;
  const d = parsed.data;
  await storage.putStartToken(env, auth.tenantId, auth.apiKeyHash, d.deviceId, d.attributesType, d.pushToken);
  return json({ ok: true });
}

export async function startLiveActivity(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req, RequestBodyLimits.liveActivity);
  const parsed = StartLiveActivitySchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const d = parsed.data;
  const limited = await enforceTenantRateLimits(env, auth, [
    { policy: "liveActivityStartTenantHour", key: tenantKey(auth.tenantId) },
  ]);
  if (limited) return limited;
  const now = new Date().toISOString();
  const countdownGranularity = d.endsAt === undefined
    ? undefined
    : d.countdownGranularity ?? "second";

  // Try push-to-start first. If any device has registered a start token for
  // ZeroZeroWidgetActivityAttributes, send the start event over APNs. Shared
  // recipients (kind-level) get the start event on their own start tokens too.
  // Each entry carries the tenant the token belongs to so dead-token pruning
  // (BadDeviceToken / Unregistered) deletes from the right tenant scope.
  const ownerStartTokens = (
    await storage.listStartTokens(env, auth.tenantId, DEFAULT_ATTRIBUTES_TYPE)
  ).map((token) => ({ token, tenantId: auth.tenantId }));
  const recipientStartTokens = await collectRecipientStartTokens(
    env,
    auth.tenantId,
    d.kind,
  );
  const startTokens = [...ownerStartTokens, ...recipientStartTokens];
  const apnsResults: unknown[] = [];
  if (startTokens.length > 0) {
    const attributes: Record<string, unknown> = {
      externalActivityId: d.externalActivityId,
      kind: d.kind,
      title: d.title,
    };
    if (d.icon !== undefined) attributes.icon = d.icon;
    if (d.deepLink) attributes.deepLink = d.deepLink;

    const contentState = initialContentState({ ...d, countdownGranularity }, now);

    for (const entry of startTokens) {
      const result = await sendLiveActivityStart(env, entry.token, {
        attributesType: DEFAULT_ATTRIBUTES_TYPE,
        attributes,
        contentState: activityKitContentState(contentState),
        staleAt: d.staleAt,
        relevanceScore: d.relevanceScore,
        alert: d.alert ?? {
          title: d.title,
          ...(d.subtitle ? { body: d.subtitle } : {}),
        },
      });
      if (result.status !== 200) {
        console.log("live activity push-to-start failed", {
          tenantId: entry.tenantId,
          externalActivityId: d.externalActivityId,
          status: result.status,
          reason: result.reason,
          apnsId: result.apnsId,
        });
        if (isDeadTokenReason(result.reason)) {
          await storage.deleteStartTokenByValue(
            env,
            entry.tenantId,
            DEFAULT_ATTRIBUTES_TYPE,
            entry.token,
          );
        }
      }
      apnsResults.push(result);
    }
  }

  // Always also queue as pending so the app can discover and start it locally
  // (push-to-start delivery isn't guaranteed; pending is the durable fallback).
  // The pending row is written on the owner's tenant; recipients pick up the
  // activity through their own /v1/live-activities/pending which we extend to
  // include shared kinds, and through the start push above.
  await storage.putPendingActivity(env, auth.tenantId, auth.apiKeyHash, d.externalActivityId, {
    ...d,
    countdownGranularity,
    startedAt: now,
    updatedAt: now,
  });
  if (isSharingEnabled(env)) {
    const accepted = await listAcceptedShares(env, auth.tenantId, "activity_kind", d.kind);
    for (const share of accepted) {
      if (!share.recipientTenantId) continue;
      // Mirror the pending row into the recipient's tenant so their app picks
      // it up the next time it polls. apiKeyHash is irrelevant for read paths
      // and we don't have a recipient key, so we synthesize a stable marker.
      await storage.putPendingActivity(
        env,
        share.recipientTenantId,
        `share:${share.id}`,
        d.externalActivityId,
        { ...d, countdownGranularity, startedAt: now, updatedAt: now },
      );
    }
  }

  return json({
    ok: true,
    pending: true,
    pushToStartAttempted: startTokens.length,
    apnsResults,
  });
}

export async function pendingActivities(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const activities = await storage.listPendingActivities(env, auth.tenantId);
  return json({ activities });
}

interface StartTokenEntry {
  token: string;
  tenantId: string;
}

async function collectRecipientStartTokens(
  env: Env,
  ownerTenantId: string,
  kind: string,
): Promise<StartTokenEntry[]> {
  if (!isSharingEnabled(env)) return [];
  const accepted = await listAcceptedShares(env, ownerTenantId, "activity_kind", kind);
  const entries: StartTokenEntry[] = [];
  for (const share of accepted) {
    if (!share.recipientTenantId) continue;
    const recipientTokens = await storage.listStartTokens(
      env,
      share.recipientTenantId,
      DEFAULT_ATTRIBUTES_TYPE,
    );
    for (const token of recipientTokens) {
      entries.push({ token, tenantId: share.recipientTenantId });
    }
  }
  return entries;
}

// APNs reasons that mean "this token is permanently dead, drop it." See:
// https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns
function isDeadTokenReason(reason: string | undefined): boolean {
  return reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic";
}

export async function updateLiveActivity(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req, RequestBodyLimits.liveActivity);
  const parsed = UpdateLiveActivitySchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const d = parsed.data;
  const limited = await enforceTenantRateLimits(env, auth, [
    { policy: "liveActivityUpdateTenantHour", key: tenantKey(auth.tenantId) },
    {
      policy: "liveActivityUpdateActivityHour",
      key: tenantResourceKey(auth.tenantId, "activity", d.externalActivityId),
    },
  ]);
  if (limited) return limited;
  const records = await storage.listActivities(env, auth.tenantId, d.externalActivityId);
  const record = records[0];
  const now = new Date().toISOString();

  const contentState = storedContentState(record?.lastState);
  if (typeof contentState.state !== "string") contentState.state = d.state ?? "unknown";
  if (d.state !== undefined) contentState.state = d.state;
  if (d.subtitle !== undefined) contentState.subtitle = d.subtitle;
  if (d.icon !== undefined) contentState.icon = d.icon;
  if (d.value !== undefined) contentState.value = d.value;
  if (d.unit !== undefined) contentState.unit = d.unit;
  if (d.progress !== undefined) contentState.progress = d.progress;
  if (d.endsAt !== undefined) contentState.endsAt = d.endsAt;
  if (typeof contentState.endsAt === "string") {
    const granularity = d.countdownGranularity ?? contentState.countdownGranularity;
    contentState.countdownGranularity = granularity === "minute" ? "minute" : "second";
  } else {
    delete contentState.countdownGranularity;
  }
  contentState.updatedAt = now;
  if (d.staleAt) contentState.staleAt = d.staleAt;

  let apnsResult: unknown = null;
  const recipientResults: unknown[] = [];
  let pendingUpdated = false;
  if (records.length > 0) {
    const ownerResults: unknown[] = [];
    for (const ownerRecord of records) {
      const result = await sendLiveActivityUpdate(env, ownerRecord.pushToken, {
        contentState: activityKitContentState(contentState),
        staleAt: d.staleAt,
        relevanceScore: d.relevanceScore,
        alert: d.alert,
      });
      ownerResults.push(result);
      await storage.putActivity(env, auth.tenantId, auth.apiKeyHash, d.externalActivityId, {
        ...ownerRecord,
        updatedAt: now,
        lastState: contentState,
      });
    }
    apnsResult = ownerResults[0] ?? null;
    // Fan out the same update to recipients that have a registered push token
    // for this externalActivityId. Their tenantId scopes the activity row.
    if (isSharingEnabled(env)) {
      const accepted = await listAcceptedShares(env, auth.tenantId, "activity_kind", record.kind);
      for (const share of accepted) {
        if (!share.recipientTenantId) continue;
        const recRecords = await storage.listActivities(env, share.recipientTenantId, d.externalActivityId);
        for (const recRecord of recRecords) {
          const r = await sendLiveActivityUpdate(env, recRecord.pushToken, {
            contentState: activityKitContentState(contentState),
            staleAt: d.staleAt,
            relevanceScore: d.relevanceScore,
            alert: d.alert,
          });
          recipientResults.push(r);
          await storage.putActivity(
            env,
            share.recipientTenantId,
            `share:${share.id}`,
            d.externalActivityId,
            { ...recRecord, updatedAt: now, lastState: contentState },
          );
        }
      }
    }
  } else {
    const pending = await storage.getPendingActivity(env, auth.tenantId, d.externalActivityId);
    if (pending) {
      const endsAt = d.endsAt ?? pending.endsAt;
      const countdownGranularity = endsAt === undefined
        ? undefined
        : d.countdownGranularity ?? pending.countdownGranularity ?? "second";
      await storage.putPendingActivity(env, auth.tenantId, auth.apiKeyHash, d.externalActivityId, {
        ...pending,
        title: d.title ?? pending.title,
        subtitle: d.subtitle ?? pending.subtitle,
        state: d.state ?? pending.state,
        icon: d.icon ?? pending.icon,
        value: d.value ?? pending.value,
        unit: d.unit ?? pending.unit,
        progress: d.progress ?? pending.progress,
        endsAt,
        countdownGranularity,
        staleAt: d.staleAt ?? pending.staleAt,
        relevanceScore: d.relevanceScore ?? pending.relevanceScore,
        updatedAt: now,
      });
      pendingUpdated = true;
    }
  }
  return json({ ok: true, apnsResult, recipientResults, pendingUpdated });
}

export async function endLiveActivity(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req, RequestBodyLimits.liveActivity);
  const parsed = EndLiveActivitySchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const d = parsed.data;
  const limited = await enforceTenantRateLimits(env, auth, [
    { policy: "liveActivityEndTenantHour", key: tenantKey(auth.tenantId) },
  ]);
  if (limited) return limited;
  const finalContentState: Record<string, unknown> = {};
  if (d.finalState) finalContentState.state = d.finalState;
  if (d.finalSubtitle) finalContentState.subtitle = d.finalSubtitle;
  const record = await storage.getActivity(env, auth.tenantId, d.externalActivityId);
  const completeFinalState = storedContentState(record?.lastState);
  Object.assign(completeFinalState, finalContentState);
  if (typeof completeFinalState.state !== "string") completeFinalState.state = "finished";
  completeFinalState.updatedAt = new Date().toISOString();
  const apnsResult = await endAndDeleteActivity(env, auth.tenantId, d.externalActivityId, {
    finalContentState: record
      ? activityKitContentState(completeFinalState)
      : undefined,
    dismissalDate: d.dismissalDate,
  });
  return json({ ok: true, apnsResult });
}

// Send the APNs end push (if we still have a push token) and delete both the
// activity row and any pending row. Used by the public end endpoint and by
// the admin Delete button so the activity actually stops on the device.
// Also fans out the end push to accepted-share recipients so their copies of
// the Live Activity terminate at the same time.
export async function endAndDeleteActivity(
  env: Env,
  tenantId: string,
  externalActivityId: string,
  endPayload: { finalContentState?: Record<string, unknown>; dismissalDate?: string } = {},
): Promise<unknown> {
  const records = await storage.listActivities(env, tenantId, externalActivityId);
  const record = records[0];
  let apnsResult: unknown = null;
  for (const [index, ownerRecord] of records.entries()) {
    const result = await sendLiveActivityEnd(env, ownerRecord.pushToken, endPayload);
    if (index === 0) apnsResult = result;
  }
  if (record && isSharingEnabled(env)) {
    const accepted = await listAcceptedShares(env, tenantId, "activity_kind", record.kind);
    for (const share of accepted) {
      if (!share.recipientTenantId) continue;
      const recRecords = await storage.listActivities(env, share.recipientTenantId, externalActivityId);
      for (const recRecord of recRecords) {
        await sendLiveActivityEnd(env, recRecord.pushToken, endPayload);
      }
      await storage.deleteActivity(env, share.recipientTenantId, externalActivityId);
      await storage.deletePendingActivity(env, share.recipientTenantId, externalActivityId);
    }
  }
  await storage.deleteActivity(env, tenantId, externalActivityId);
  await storage.deletePendingActivity(env, tenantId, externalActivityId);
  return apnsResult;
}
