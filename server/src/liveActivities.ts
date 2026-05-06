import type { Env } from "./types";
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
  await storage.putActivity(env, auth.tenantId, auth.apiKeyHash, d.externalActivityId, {
    pushToken: d.pushToken,
    deviceId: d.deviceId,
    localActivityId: d.localActivityId,
    kind: d.kind,
    updatedAt: new Date().toISOString(),
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

  // Try push-to-start first. If any device has registered a start token for
  // ZeroZeroWidgetActivityAttributes, send the start event over APNs. Shared
  // recipients (kind-level) get the start event on their own start tokens too.
  const ownerStartTokens = await storage.listStartTokens(
    env,
    auth.tenantId,
    DEFAULT_ATTRIBUTES_TYPE,
  );
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

    const contentState: Record<string, unknown> = {
      state: d.state,
      updatedAt: now,
    };
    if (d.subtitle !== undefined) contentState.subtitle = d.subtitle;
    if (d.icon !== undefined) contentState.icon = d.icon;
    if (d.value !== undefined) contentState.value = d.value;
    if (d.unit !== undefined) contentState.unit = d.unit;
    if (d.progress !== undefined) contentState.progress = d.progress;
    if (d.endsAt) contentState.endsAt = d.endsAt;
    if (d.staleAt) contentState.staleAt = d.staleAt;

    for (const token of startTokens) {
      const result = await sendLiveActivityStart(env, token, {
        attributesType: DEFAULT_ATTRIBUTES_TYPE,
        attributes,
        contentState,
        staleAt: d.staleAt,
        relevanceScore: d.relevanceScore,
      });
      if (result.status !== 200) {
        console.log("live activity push-to-start failed", {
          tenantId: auth.tenantId,
          externalActivityId: d.externalActivityId,
          status: result.status,
          reason: result.reason,
          apnsId: result.apnsId,
        });
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
        { ...d, startedAt: now, updatedAt: now },
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

async function collectRecipientStartTokens(
  env: Env,
  ownerTenantId: string,
  kind: string,
): Promise<string[]> {
  if (!isSharingEnabled(env)) return [];
  const accepted = await listAcceptedShares(env, ownerTenantId, "activity_kind", kind);
  const tokens: string[] = [];
  for (const share of accepted) {
    if (!share.recipientTenantId) continue;
    const recipientTokens = await storage.listStartTokens(
      env,
      share.recipientTenantId,
      DEFAULT_ATTRIBUTES_TYPE,
    );
    tokens.push(...recipientTokens);
  }
  return tokens;
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
  const record = await storage.getActivity(env, auth.tenantId, d.externalActivityId);
  const now = new Date().toISOString();

  const contentState: Record<string, unknown> = {};
  if (d.state !== undefined) contentState.state = d.state;
  if (d.subtitle !== undefined) contentState.subtitle = d.subtitle;
  if (d.icon !== undefined) contentState.icon = d.icon;
  if (d.value !== undefined) contentState.value = d.value;
  if (d.unit !== undefined) contentState.unit = d.unit;
  if (d.progress !== undefined) contentState.progress = d.progress;
  if (d.endsAt !== undefined) contentState.endsAt = d.endsAt;
  contentState.updatedAt = now;
  if (d.staleAt) contentState.staleAt = d.staleAt;

  let apnsResult: unknown = null;
  const recipientResults: unknown[] = [];
  let pendingUpdated = false;
  if (record?.pushToken) {
    apnsResult = await sendLiveActivityUpdate(env, record.pushToken, {
      contentState,
      staleAt: d.staleAt,
      relevanceScore: d.relevanceScore,
      alert: d.alert,
    });
    await storage.putActivity(env, auth.tenantId, auth.apiKeyHash, d.externalActivityId, {
      ...record,
      updatedAt: now,
      lastState: contentState,
    });
    // Fan out the same update to recipients that have a registered push token
    // for this externalActivityId. Their tenantId scopes the activity row.
    if (isSharingEnabled(env)) {
      const accepted = await listAcceptedShares(env, auth.tenantId, "activity_kind", record.kind);
      for (const share of accepted) {
        if (!share.recipientTenantId) continue;
        const recRecord = await storage.getActivity(env, share.recipientTenantId, d.externalActivityId);
        if (!recRecord?.pushToken) continue;
        const r = await sendLiveActivityUpdate(env, recRecord.pushToken, {
          contentState,
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
  } else {
    const pending = await storage.getPendingActivity(env, auth.tenantId, d.externalActivityId);
    if (pending) {
      await storage.putPendingActivity(env, auth.tenantId, auth.apiKeyHash, d.externalActivityId, {
        ...pending,
        title: d.title ?? pending.title,
        subtitle: d.subtitle ?? pending.subtitle,
        state: d.state ?? pending.state,
        icon: d.icon ?? pending.icon,
        value: d.value ?? pending.value,
        unit: d.unit ?? pending.unit,
        progress: d.progress ?? pending.progress,
        endsAt: d.endsAt ?? pending.endsAt,
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
  const apnsResult = await endAndDeleteActivity(env, auth.tenantId, d.externalActivityId, {
    finalContentState: Object.keys(finalContentState).length ? finalContentState : undefined,
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
  const record = await storage.getActivity(env, tenantId, externalActivityId);
  let apnsResult: unknown = null;
  if (record?.pushToken) {
    apnsResult = await sendLiveActivityEnd(env, record.pushToken, endPayload);
  }
  if (record && isSharingEnabled(env)) {
    const accepted = await listAcceptedShares(env, tenantId, "activity_kind", record.kind);
    for (const share of accepted) {
      if (!share.recipientTenantId) continue;
      const recRecord = await storage.getActivity(env, share.recipientTenantId, externalActivityId);
      if (recRecord?.pushToken) {
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
