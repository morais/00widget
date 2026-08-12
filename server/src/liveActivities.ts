import type {
  CountdownGranularity,
  Env,
  LiveActivitySession,
} from "./types";
import {
  RegisterLiveActivitySchema,
  RegisterLiveActivityStartTokenSchema,
  StartLiveActivitySchema,
  UpdateLiveActivitySchema,
  EndLiveActivitySchema,
  LiveActivitySessionSchema,
  RequestBodyLimits,
} from "./types";
import * as storage from "./storage";
import {
  sendLiveActivityStart,
  sendLiveActivityUpdate,
  sendLiveActivityEnd,
  type ApnsResult,
} from "./apns";
import { json, badRequest, notFound } from "./http";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";
import { isSharingEnabled, listAcceptedShares } from "./shares";
import { enforceTenantRateLimits, tenantKey, tenantResourceKey } from "./rateLimit";

// The Swift attributes type the iOS app declares. iOS 18+ rejects start
// pushes whose attributes-type doesn't match a registered ActivityAttributes.
const DEFAULT_ATTRIBUTES_TYPE = "ZeroZeroWidgetActivityAttributes";
const APPLE_REFERENCE_DATE_UNIX_SECONDS = 978_307_200;
const MAX_ACTIVITYKIT_DATA_BYTES = 4 * 1024;

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
    items?: LiveActivitySession["items"];
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
  if (activity.items !== undefined) state.items = activity.items;
  if (activity.endsAt !== undefined) {
    state.endsAt = activity.endsAt;
    state.countdownGranularity = activity.countdownGranularity ?? "second";
  }
  if (activity.staleAt !== undefined) state.staleAt = activity.staleAt;
  return state;
}

function activityKitContentState(state: ContentStateRecord): ContentStateRecord {
  const encoded = { ...state };
  for (const key of ["updatedAt", "endsAt", "staleAt"] as const) {
    const value = encoded[key];
    if (typeof value === "string") encoded[key] = activityKitDate(value);
  }
  return encoded;
}

function liveActivityDataSizeError(
  attributes: Record<string, unknown>,
  contentState: ContentStateRecord,
): string | null {
  const encoder = new TextEncoder();
  const bytes = encoder.encode(JSON.stringify({
    attributes,
    "content-state": activityKitContentState(contentState),
  })).byteLength;
  return bytes > MAX_ACTIVITYKIT_DATA_BYTES
    ? `combined ActivityKit attributes and content state exceed ${MAX_ACTIVITYKIT_DATA_BYTES} bytes`
    : null;
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
  let instance = d.activityInstanceId
    ? await storage.getActivityInstanceForTarget(env, d.activityInstanceId, auth.tenantId)
    : null;
  if (!d.activityInstanceId) {
    const candidates = await storage.resolveActivityRegistrationTargets(
      env,
      auth.tenantId,
      d.externalActivityId,
      d.kind,
    );
    if (candidates.length > 1) {
      return json({ error: "activityInstanceId is required for ambiguous registration" }, 409);
    }
    instance = candidates[0] ?? null;
    if (!instance) {
      // Compatibility for activities created locally by older app builds.
      const now = new Date().toISOString();
      instance = LiveActivitySessionSchema.parse({
        activityInstanceId: crypto.randomUUID(),
        externalActivityId: d.externalActivityId,
        kind: d.kind,
        title: d.externalActivityId,
        state: "unknown",
        updatedAt: now,
      });
      await storage.putActivityInstance(env, auth.tenantId, auth.apiKeyHash, instance);
      await storage.putActivityTarget(
        env,
        instance.activityInstanceId,
        auth.tenantId,
        auth.tenantId,
      );
    }
  }
  if (!instance) return notFound();
  const target = await storage.getActivityTarget(
    env,
    instance.activityInstanceId,
    auth.tenantId,
  );
  if (!target) return notFound();
  if (instance.externalActivityId !== d.externalActivityId || instance.kind !== d.kind) {
    return badRequest("activity registration does not match its instance");
  }
  const now = new Date().toISOString();
  await storage.putActivityDelivery(env, {
    activityInstanceId: instance.activityInstanceId,
    ownerTenantId: target.ownerTenantId,
    targetTenantId: auth.tenantId,
    shareId: target.shareId,
    apiKeyHash: auth.apiKeyHash,
    record: {
      pushToken: d.pushToken,
      deviceId: d.deviceId,
      localActivityId: d.localActivityId,
      kind: d.kind,
      title: instance.title,
      icon: instance.icon,
      deepLink: instance.deepLink,
      startedAt: instance.startedAt,
      relevanceScore: instance.relevanceScore,
      updatedAt: now,
      lastState: initialContentState(instance, instance.updatedAt),
    },
  });
  return json({ ok: true, activityInstanceId: instance.activityInstanceId });
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

  const existing = await storage.getActivityInstanceByOwnerExternal(
    env,
    auth.tenantId,
    d.externalActivityId,
  );
  if (existing && existing.kind !== d.kind) {
    return json({ error: "an active instance already uses this externalActivityId with another kind" }, 409);
  }
  const activityInstanceId = existing?.activityInstanceId ?? crypto.randomUUID();
  const session = LiveActivitySessionSchema.parse({
    activityInstanceId,
    externalActivityId: d.externalActivityId,
    kind: d.kind,
    title: d.title,
    subtitle: d.subtitle,
    state: d.state,
    icon: d.icon,
    value: d.value,
    unit: d.unit,
    progress: d.progress,
    items: d.items,
    endsAt: d.endsAt,
    countdownGranularity,
    startedAt: existing?.startedAt ?? now,
    updatedAt: now,
    staleAt: d.staleAt,
    relevanceScore: d.relevanceScore,
    deepLink: d.deepLink,
  });
  const initialState = initialContentState(session, now);
  const attributesForSizeCheck: Record<string, unknown> = {
    activityInstanceId,
    externalActivityId: d.externalActivityId,
    kind: d.kind,
    title: d.title,
  };
  if (d.icon !== undefined) attributesForSizeCheck.icon = d.icon;
  if (d.deepLink) attributesForSizeCheck.deepLink = d.deepLink;
  const sizeError = liveActivityDataSizeError(attributesForSizeCheck, initialState);
  if (sizeError) return badRequest(sizeError);
  await storage.putActivityInstance(env, auth.tenantId, auth.apiKeyHash, session);

  const targets: Array<{ tenantId: string; shareId?: string }> = [
    { tenantId: auth.tenantId },
  ];
  if (isSharingEnabled(env)) {
    const accepted = await listAcceptedShares(env, auth.tenantId, "activity_kind", d.kind);
    for (const share of accepted) {
      if (share.recipientTenantId) {
        targets.push({ tenantId: share.recipientTenantId, shareId: share.id });
      }
    }
  }
  for (const target of targets) {
    await storage.putActivityTarget(
      env,
      activityInstanceId,
      auth.tenantId,
      target.tenantId,
      target.shareId,
    );
  }

  const startTokens: StartTokenEntry[] = [];
  for (const target of targets) {
    const tokens = await storage.listStartTokens(env, target.tenantId, DEFAULT_ATTRIBUTES_TYPE);
    for (const token of tokens) startTokens.push({ token, tenantId: target.tenantId });
  }
  const apnsResults: unknown[] = [];
  if (startTokens.length > 0) {
    const attributes: Record<string, unknown> = {
      activityInstanceId,
      externalActivityId: d.externalActivityId,
      kind: d.kind,
      title: d.title,
    };
    if (d.icon !== undefined) attributes.icon = d.icon;
    if (d.deepLink) attributes.deepLink = d.deepLink;

    const contentState = initialState;

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

  return json({
    ok: true,
    activityInstanceId,
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

export async function activeActivities(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  return json({ activities: await listActiveActivitySessions(env, auth.tenantId) });
}

export async function listActiveActivitySessions(
  env: Env,
  tenantId: string,
): Promise<LiveActivitySession[]> {
  return storage.listActivityInstancesForTarget(env, tenantId);
}

interface StartTokenEntry {
  token: string;
  tenantId: string;
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
  const instance = await storage.getActivityInstanceByOwnerExternal(
    env,
    auth.tenantId,
    d.externalActivityId,
  );
  if (!instance) return notFound();
  const now = new Date().toISOString();
  const endsAt = d.endsAt ?? instance.endsAt;
  const countdownGranularity = endsAt === undefined
    ? undefined
    : d.countdownGranularity ?? instance.countdownGranularity ?? "second";
  const updated = LiveActivitySessionSchema.parse({
    ...instance,
    title: d.title ?? instance.title,
    subtitle: d.subtitle ?? instance.subtitle,
    state: d.state ?? instance.state,
    icon: d.icon ?? instance.icon,
    value: d.value ?? instance.value,
    unit: d.unit ?? instance.unit,
    progress: d.progress ?? instance.progress,
    items: d.items ?? instance.items,
    endsAt,
    countdownGranularity,
    staleAt: d.staleAt ?? instance.staleAt,
    relevanceScore: d.relevanceScore ?? instance.relevanceScore,
    updatedAt: now,
  });
  const contentState = initialContentState(updated, now);
  const attributesForSizeCheck: Record<string, unknown> = {
    activityInstanceId: instance.activityInstanceId,
    externalActivityId: instance.externalActivityId,
    kind: instance.kind,
    title: instance.title,
  };
  if (instance.icon !== undefined) attributesForSizeCheck.icon = instance.icon;
  if (updated.deepLink) attributesForSizeCheck.deepLink = updated.deepLink;
  const sizeError = liveActivityDataSizeError(attributesForSizeCheck, contentState);
  if (sizeError) return badRequest(sizeError);
  await storage.putActivityInstance(env, auth.tenantId, auth.apiKeyHash, updated);
  const deliveries = (await storage.listActivityDeliveries(env, instance.activityInstanceId))
    .filter((delivery) => !delivery.shareId || isSharingEnabled(env));

  let apnsResult: unknown = null;
  const recipientResults: unknown[] = [];
  for (const delivery of deliveries) {
    const result = await sendLiveActivityUpdate(env, delivery.record.pushToken, {
      contentState: activityKitContentState(contentState),
      staleAt: d.staleAt,
      relevanceScore: d.relevanceScore,
      alert: d.alert,
    });
    if (delivery.targetTenantId === auth.tenantId) {
      apnsResult ??= result;
    } else {
      recipientResults.push(result);
    }
    await storage.putActivityDelivery(env, {
      ...delivery,
      record: {
        ...delivery.record,
        title: updated.title,
        icon: updated.icon,
        deepLink: updated.deepLink,
        relevanceScore: updated.relevanceScore,
        updatedAt: now,
        lastState: contentState,
      },
    });
  }
  return json({
    ok: true,
    activityInstanceId: instance.activityInstanceId,
    apnsResult,
    recipientResults,
    pendingUpdated: deliveries.length === 0,
  });
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
  const instance = await storage.getActivityInstanceByOwnerExternal(
    env,
    auth.tenantId,
    d.externalActivityId,
  );
  const completeFinalState = instance
    ? initialContentState(instance, instance.updatedAt)
    : {};
  Object.assign(completeFinalState, finalContentState);
  if (typeof completeFinalState.state !== "string") completeFinalState.state = "finished";
  completeFinalState.updatedAt = new Date().toISOString();
  const result = await endAndDeleteActivity(env, auth.tenantId, d.externalActivityId, {
    finalContentState: instance
      ? activityKitContentState(completeFinalState)
      : undefined,
    dismissalDate: d.dismissalDate,
  });
  if (result.deliveryFailures.length > 0) {
    return json({
      error: "live activity end delivery failed; activity retained for retry",
      apnsResult: result.apnsResult,
      recipientResults: result.recipientResults,
      deliveryFailures: result.deliveryFailures,
    }, 502);
  }
  return json({
    ok: true,
    apnsResult: result.apnsResult,
    recipientResults: result.recipientResults,
  });
}

export interface EndAndDeleteActivityResult {
  apnsResult: ApnsResult | null;
  recipientResults: ApnsResult[];
  deliveryFailures: ApnsResult[];
}

function endDeliverySucceeded(result: ApnsResult): boolean {
  return result.status === 200 || isDeadTokenReason(result.reason);
}

// Send the APNs end push to the exact deliveries bound to the owner-scoped
// instance. Delete the instance only after every delivery reaches a terminal
// result so the producer can safely retry transient failures.
export async function endAndDeleteActivity(
  env: Env,
  tenantId: string,
  externalActivityId: string,
  endPayload: { finalContentState?: Record<string, unknown>; dismissalDate?: string } = {},
  options: { deleteOnDeliveryFailure?: boolean } = {},
): Promise<EndAndDeleteActivityResult> {
  const instance = await storage.getActivityInstanceByOwnerExternal(
    env,
    tenantId,
    externalActivityId,
  );
  if (!instance) {
    return { apnsResult: null, recipientResults: [], deliveryFailures: [] };
  }
  const deliveries = (await storage.listActivityDeliveries(env, instance.activityInstanceId))
    .filter((delivery) => !delivery.shareId || isSharingEnabled(env));
  let apnsResult: ApnsResult | null = null;
  const recipientResults: ApnsResult[] = [];
  const deliveryFailures: ApnsResult[] = [];
  for (const delivery of deliveries) {
    const result = await sendLiveActivityEnd(env, delivery.record.pushToken, endPayload);
    if (delivery.targetTenantId === tenantId) {
      apnsResult ??= result;
    } else {
      recipientResults.push(result);
    }
    if (!endDeliverySucceeded(result)) deliveryFailures.push(result);
  }
  if (deliveryFailures.length === 0 || options.deleteOnDeliveryFailure === true) {
    await storage.deleteActivityInstance(env, instance.activityInstanceId);
  }
  return { apnsResult, recipientResults, deliveryFailures };
}
