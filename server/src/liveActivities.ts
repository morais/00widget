import type { Env } from "./types";
import {
  RegisterLiveActivitySchema,
  RegisterLiveActivityStartTokenSchema,
  StartLiveActivitySchema,
  UpdateLiveActivitySchema,
  EndLiveActivitySchema,
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

// The Swift attributes type the iOS app declares. iOS 18+ rejects start
// pushes whose attributes-type doesn't match a registered ActivityAttributes.
const DEFAULT_ATTRIBUTES_TYPE = "ZeroZeroWidgetActivityAttributes";

export async function registerLiveActivity(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req);
  const parsed = RegisterLiveActivitySchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const d = parsed.data;
  await storage.putActivity(env, auth.apiKeyHash, d.externalActivityId, {
    pushToken: d.pushToken,
    deviceId: d.deviceId,
    localActivityId: d.localActivityId,
    kind: d.kind,
    updatedAt: new Date().toISOString(),
  });
  await storage.deletePendingActivity(env, auth.apiKeyHash, d.externalActivityId);
  return json({ ok: true });
}

export async function registerLiveActivityStartToken(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req);
  const parsed = RegisterLiveActivityStartTokenSchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const d = parsed.data;
  await storage.putStartToken(env, auth.apiKeyHash, d.deviceId, d.attributesType, d.pushToken);
  return json({ ok: true });
}

export async function startLiveActivity(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req);
  const parsed = StartLiveActivitySchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const d = parsed.data;
  const now = new Date().toISOString();

  // Try push-to-start first. If any device has registered a start token for
  // ZeroZeroWidgetActivityAttributes, send the start event over APNs.
  const startTokens = await storage.listStartTokens(env, auth.apiKeyHash, DEFAULT_ATTRIBUTES_TYPE);
  const apnsResults: unknown[] = [];
  if (startTokens.length > 0) {
    const attributes: Record<string, unknown> = {
      externalActivityId: d.externalActivityId,
      kind: d.kind,
      title: d.title,
    };
    if (d.deepLink) attributes.deepLink = d.deepLink;

    const contentState: Record<string, unknown> = {
      state: d.state,
      updatedAt: now,
    };
    if (d.subtitle !== undefined) contentState.subtitle = d.subtitle;
    if (d.value !== undefined) contentState.value = d.value;
    if (d.unit !== undefined) contentState.unit = d.unit;
    if (d.progress !== undefined) contentState.progress = d.progress;
    if (d.staleAt) contentState.staleAt = d.staleAt;

    for (const token of startTokens) {
      const result = await sendLiveActivityStart(env, token, {
        attributesType: DEFAULT_ATTRIBUTES_TYPE,
        attributes,
        contentState,
        staleAt: d.staleAt,
      });
      apnsResults.push(result);
    }
  }

  // Always also queue as pending so the app can discover and start it locally
  // (push-to-start delivery isn't guaranteed; pending is the durable fallback).
  await storage.putPendingActivity(env, auth.apiKeyHash, d.externalActivityId, {
    ...d,
    startedAt: now,
    updatedAt: now,
  });

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
  const activities = await storage.listPendingActivities(env, auth.apiKeyHash);
  return json({ activities });
}

export async function updateLiveActivity(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req);
  const parsed = UpdateLiveActivitySchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const d = parsed.data;
  const record = await storage.getActivity(env, auth.apiKeyHash, d.externalActivityId);
  const now = new Date().toISOString();

  const contentState: Record<string, unknown> = {};
  if (d.state !== undefined) contentState.state = d.state;
  if (d.subtitle !== undefined) contentState.subtitle = d.subtitle;
  if (d.value !== undefined) contentState.value = d.value;
  if (d.unit !== undefined) contentState.unit = d.unit;
  if (d.progress !== undefined) contentState.progress = d.progress;
  contentState.updatedAt = now;
  if (d.staleAt) contentState.staleAt = d.staleAt;

  let apnsResult: unknown = null;
  let pendingUpdated = false;
  if (record?.pushToken) {
    apnsResult = await sendLiveActivityUpdate(env, record.pushToken, {
      contentState,
      staleAt: d.staleAt,
      alert: d.alert,
    });
    await storage.putActivity(env, auth.apiKeyHash, d.externalActivityId, {
      ...record,
      updatedAt: now,
      lastState: contentState,
    });
  } else {
    const pending = await storage.getPendingActivity(env, auth.apiKeyHash, d.externalActivityId);
    if (pending) {
      await storage.putPendingActivity(env, auth.apiKeyHash, d.externalActivityId, {
        ...pending,
        title: d.title ?? pending.title,
        subtitle: d.subtitle ?? pending.subtitle,
        state: d.state ?? pending.state,
        value: d.value ?? pending.value,
        unit: d.unit ?? pending.unit,
        progress: d.progress ?? pending.progress,
        staleAt: d.staleAt ?? pending.staleAt,
        updatedAt: now,
      });
      pendingUpdated = true;
    }
  }
  return json({ ok: true, apnsResult, pendingUpdated });
}

export async function endLiveActivity(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req);
  const parsed = EndLiveActivitySchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const d = parsed.data;
  const record = await storage.getActivity(env, auth.apiKeyHash, d.externalActivityId);

  let apnsResult: unknown = null;
  if (record?.pushToken) {
    const finalContentState: Record<string, unknown> = {};
    if (d.finalState) finalContentState.state = d.finalState;
    if (d.finalSubtitle) finalContentState.subtitle = d.finalSubtitle;
    apnsResult = await sendLiveActivityEnd(env, record.pushToken, {
      finalContentState: Object.keys(finalContentState).length ? finalContentState : undefined,
      dismissalDate: d.dismissalDate,
    });
  }
  await storage.deleteActivity(env, auth.apiKeyHash, d.externalActivityId);
  await storage.deletePendingActivity(env, auth.apiKeyHash, d.externalActivityId);
  return json({ ok: true, apnsResult });
}
