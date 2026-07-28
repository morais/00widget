import type { Env } from "./types";

// APNs payload shapes verified against Apple's current docs as of 2026-07-28:
//   https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
//   https://developer.apple.com/documentation/WidgetKit/Updating-widgets-with-widgetkit-push-notifications
// If Apple changes payload field names, header values, or priority requirements
// in a future iOS, re-verify before shipping.

export interface ApnsResult {
  status: number;
  reason?: string;
  apnsId?: string | null;
}

export interface ApnsSendOptions {
  pushToken: string;
  pushType: "liveactivity" | "widgets" | "alert" | "background";
  topic: string;
  priority?: 5 | 10;
  expiration?: number; // unix seconds
  payload: unknown;
  collapseId?: string;
  fetcher?: typeof fetch;
}

const CACHE_TTL_SECONDS = 50 * 60;
let cachedJwt: { token: string; expiresAt: number } | null = null;

export function apnsConfigured(env: Env): boolean {
  return Boolean(env.APNS_TEAM_ID && env.APNS_KEY_ID && env.APNS_PRIVATE_KEY && env.APNS_BUNDLE_ID);
}

export function apnsHost(env: Env): string {
  return env.APNS_ENV === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
}

export async function sendApnsPush(env: Env, opts: ApnsSendOptions): Promise<ApnsResult> {
  if (!apnsConfigured(env)) {
    return { status: 0, reason: "apns-not-configured" };
  }

  const jwt = await getJwt(env);
  const url = `https://${apnsHost(env)}/3/device/${opts.pushToken}`;
  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-topic": opts.topic,
    "apns-push-type": opts.pushType,
    "apns-priority": String(opts.priority ?? 10),
  };
  if (opts.expiration !== undefined) headers["apns-expiration"] = String(opts.expiration);
  if (opts.collapseId) headers["apns-collapse-id"] = opts.collapseId;

  const doFetch = opts.fetcher ?? fetch;
  const response = await doFetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify(opts.payload),
  });

  const apnsId = response.headers.get("apns-id");
  if (response.status === 200) {
    return { status: 200, apnsId };
  }
  let reason: string | undefined;
  try {
    const data = (await response.json()) as { reason?: string };
    reason = data.reason;
  } catch {
    /* ignore */
  }
  return { status: response.status, reason, apnsId };
}

export interface LiveActivityUpdatePayload {
  contentState: Record<string, unknown>;
  staleAt?: string;
  // aps.relevance-score (iOS 16.2+). Smart Stack on iPhone / Apple Watch
  // ranks Live Activities by this — higher wins, no fixed ceiling.
  relevanceScore?: number;
  alert?: { title: string; body?: string };
}

export async function sendLiveActivityUpdate(
  env: Env,
  pushToken: string,
  payload: LiveActivityUpdatePayload,
): Promise<ApnsResult> {
  // Live Activity update: aps.timestamp + aps.event = "update" + aps.content-state.
  // Priority 10 is required for user-visible changes; use 5 for background-only refresh.
  const aps: Record<string, unknown> = {
    timestamp: Math.floor(Date.now() / 1000),
    event: "update",
    "content-state": payload.contentState,
  };
  if (payload.staleAt) aps["stale-date"] = Math.floor(new Date(payload.staleAt).getTime() / 1000);
  if (payload.relevanceScore !== undefined) aps["relevance-score"] = payload.relevanceScore;
  if (payload.alert) aps.alert = payload.alert;

  return sendApnsPush(env, {
    pushToken,
    pushType: "liveactivity",
    topic: `${env.APNS_BUNDLE_ID}.push-type.liveactivity`,
    priority: 10,
    payload: { aps },
  });
}

export interface LiveActivityStartPayload {
  attributesType: string;
  attributes: Record<string, unknown>;
  contentState: Record<string, unknown>;
  staleAt?: string;
  relevanceScore?: number;
  alert: { title: string; body?: string };
}

export async function sendLiveActivityStart(
  env: Env,
  pushToken: string,
  payload: LiveActivityStartPayload,
): Promise<ApnsResult> {
  // Push-to-start (iOS 17.2+): aps.event = "start" + attributes-type + attributes
  // + content-state. The token comes from Activity<Attrs>.pushToStartTokenUpdates
  // and is per-attribute-type (one token represents the ability to start any
  // instance of that ActivityAttributes).
  const aps: Record<string, unknown> = {
    timestamp: Math.floor(Date.now() / 1000),
    event: "start",
    "attributes-type": payload.attributesType,
    attributes: payload.attributes,
    "content-state": payload.contentState,
    // iOS 18+ only issues the per-activity token needed for later update/end
    // pushes when the start payload explicitly requests one.
    "input-push-token": 1,
    // Apple requires an alert on push-to-start notifications so a Live
    // Activity never appears without telling the user.
    alert: payload.alert,
  };
  if (payload.staleAt) aps["stale-date"] = Math.floor(new Date(payload.staleAt).getTime() / 1000);
  if (payload.relevanceScore !== undefined) aps["relevance-score"] = payload.relevanceScore;

  return sendApnsPush(env, {
    pushToken,
    pushType: "liveactivity",
    topic: `${env.APNS_BUNDLE_ID}.push-type.liveactivity`,
    priority: 10,
    payload: { aps },
  });
}

export interface LiveActivityEndPayload {
  finalContentState?: Record<string, unknown>;
  dismissalDate?: string;
  alert?: { title: string; body?: string };
}

export async function sendLiveActivityEnd(
  env: Env,
  pushToken: string,
  payload: LiveActivityEndPayload = {},
): Promise<ApnsResult> {
  // Live Activity end: aps.event = "end". `dismissal-date` is unix seconds —
  // omit to let iOS apply the default dismissal policy (~4 hours).
  const aps: Record<string, unknown> = {
    timestamp: Math.floor(Date.now() / 1000),
    event: "end",
  };
  if (payload.finalContentState) aps["content-state"] = payload.finalContentState;
  if (payload.dismissalDate) aps["dismissal-date"] = Math.floor(new Date(payload.dismissalDate).getTime() / 1000);
  if (payload.alert) aps.alert = payload.alert;

  return sendApnsPush(env, {
    pushToken,
    pushType: "liveactivity",
    topic: `${env.APNS_BUNDLE_ID}.push-type.liveactivity`,
    priority: 10,
    payload: { aps },
  });
}

export async function sendWidgetReloadPush(env: Env, pushToken: string): Promise<ApnsResult> {
  // WidgetKit push (iOS 18+): apns-push-type: widgets,
  // apns-topic: <bundle>.push-type.widgets. Apple's docs require
  // `aps.content-changed: true` to signal that timelines should reload.
  return sendApnsPush(env, {
    pushToken,
    pushType: "widgets",
    topic: `${env.APNS_BUNDLE_ID}.push-type.widgets`,
    priority: 5,
    payload: { aps: { "content-changed": true } },
  });
}

async function getJwt(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.expiresAt > now) return cachedJwt.token;

  const header = { alg: "ES256", kid: env.APNS_KEY_ID! };
  const claims = { iss: env.APNS_TEAM_ID!, iat: now };

  const encHeader = b64url(JSON.stringify(header));
  const encClaims = b64url(JSON.stringify(claims));
  const signingInput = `${encHeader}.${encClaims}`;

  const key = await importP8(env.APNS_PRIVATE_KEY!);
  const signatureBuf = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  const signature = b64url(new Uint8Array(signatureBuf));
  const token = `${signingInput}.${signature}`;
  cachedJwt = { token, expiresAt: now + CACHE_TTL_SECONDS };
  return token;
}

function b64url(input: string | Uint8Array): string {
  let bytes: Uint8Array;
  if (typeof input === "string") {
    bytes = new TextEncoder().encode(input);
  } else {
    bytes = input;
  }
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  const b64 = btoa(binary);
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function importP8(pem: string): Promise<CryptoKey> {
  const normalized = pem.replace(/\\n/g, "\n");
  const body = normalized
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bytes = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    bytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

// Test-only helper: resets the JWT cache so unit tests don't interfere.
export function __resetApnsJwtCache(): void {
  cachedJwt = null;
}
