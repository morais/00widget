import type { Env } from "./types";
import {
  RegisterLiveActivitySchema,
  StartLiveActivitySchema,
  UpdateLiveActivitySchema,
  EndLiveActivitySchema,
} from "./types";
import * as storage from "./storage";
import { sendLiveActivityUpdate, sendLiveActivityEnd } from "./apns";
import { json, badRequest } from "./http";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";

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
  await storage.putPendingActivity(env, auth.apiKeyHash, parsed.data.externalActivityId, parsed.data);
  // Future: if iOS-side push-to-start tokens (Activity.pushToStartTokenUpdates,
  // iOS 17.2+) are observed and registered, we could send a `start` APNs push
  // here instead of waiting for the app to discover the pending activity.
  return json({ ok: true, pending: true });
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

  const contentState: Record<string, unknown> = {};
  if (d.state !== undefined) contentState.state = d.state;
  if (d.subtitle !== undefined) contentState.subtitle = d.subtitle;
  if (d.value !== undefined) contentState.value = d.value;
  if (d.unit !== undefined) contentState.unit = d.unit;
  if (d.progress !== undefined) contentState.progress = d.progress;
  contentState.updatedAt = new Date().toISOString();
  if (d.staleAt) contentState.staleAt = d.staleAt;

  let apnsResult: unknown = null;
  if (record?.pushToken) {
    apnsResult = await sendLiveActivityUpdate(env, record.pushToken, {
      contentState,
      staleAt: d.staleAt,
      alert: d.alert,
    });
    await storage.putActivity(env, auth.apiKeyHash, d.externalActivityId, {
      ...record,
      updatedAt: new Date().toISOString(),
      lastState: contentState,
    });
  }
  return json({ ok: true, apnsResult });
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
  return json({ ok: true, apnsResult });
}
