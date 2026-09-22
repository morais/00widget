import { json } from "./http";
import {
  configuredMetaSubscriptionSku,
  isMetaSubscriptionsEnabled,
  MetaSubscriptionRejected,
  parseMetaSubscriptionSnapshot,
  recordMetaSubscription,
} from "./metaSubscription";
import { enforceRateLimits } from "./rateLimit";
import { subscriptionsDisabledResponse } from "./subscription";
import { RequestBodyLimits, type Env } from "./types";

const SUBSCRIPTION_FIELDS = new Set([
  "subscription_started",
  "subscription_renewal_success",
  "subscription_canceled",
  "subscription_uncanceled",
  "subscription_expired",
]);

export async function verifyMetaSubscriptionWebhook(req: Request, env: Env): Promise<Response> {
  if (!isMetaSubscriptionsEnabled(env)) return subscriptionsDisabledResponse();
  const expected = (env.META_WEBHOOK_VERIFY_TOKEN ?? "").trim();
  const url = new URL(req.url);
  const valid = expected
    && url.searchParams.get("hub.mode") === "subscribe"
    && url.searchParams.get("hub.verify_token") === expected;
  if (!valid) return json({ error: "webhook verification failed" }, 403);
  return new Response(url.searchParams.get("hub.challenge") ?? "", {
    status: 200,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

export async function handleMetaSubscriptionWebhook(req: Request, env: Env): Promise<Response> {
  if (!isMetaSubscriptionsEnabled(env)) return subscriptionsDisabledResponse();
  const appId = (env.META_APP_ID ?? "").trim();
  const appSecret = (env.META_APP_SECRET ?? "").trim();
  const sku = configuredMetaSubscriptionSku(env);
  if (!appId || !appSecret || !sku) {
    console.warn("meta.webhook.not_configured", {
      appId: Boolean(appId),
      appSecret: Boolean(appSecret),
      sku: Boolean(sku),
    });
    return json({ error: "Meta subscriptions are not configured" }, 503);
  }

  const ip = req.headers.get("cf-connecting-ip")?.trim() || "unknown";
  const limited = await enforceRateLimits(env, [
    { policy: "metaNotificationIpHour", key: `ip:${ip}` },
  ]);
  if (limited) return limited;

  let raw: string;
  try {
    raw = await readBodyUpTo(req, RequestBodyLimits.metaWebhook);
  } catch {
    return json({ error: "request body is too large" }, 413);
  }
  if (!await verifySignature(raw, req.headers.get("x-hub-signature-256"), appSecret)) {
    return json({ error: "notification failed verification" }, 401);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(raw);
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  if (!payload || typeof payload !== "object") {
    return json({ error: "invalid webhook body" }, 400);
  }
  const root = payload as Record<string, unknown>;
  if (root.object !== "application" || !Array.isArray(root.entry)) {
    return json({ error: "invalid webhook body" }, 400);
  }

  let applied = 0;
  let ignored = 0;
  for (const rawEntry of root.entry) {
    if (!rawEntry || typeof rawEntry !== "object") {
      ignored++;
      continue;
    }
    const entry = rawEntry as Record<string, unknown>;
    if (String(entry.id ?? "") !== appId || !Array.isArray(entry.changes)) {
      ignored++;
      continue;
    }
    const eventTimeMs = eventTimestamp(entry.time);
    if (eventTimeMs === null) {
      ignored += entry.changes.length;
      continue;
    }
    for (const rawChange of entry.changes) {
      if (!rawChange || typeof rawChange !== "object") {
        ignored++;
        continue;
      }
      const change = rawChange as Record<string, unknown>;
      const field = typeof change.field === "string" ? change.field : "";
      if (!SUBSCRIPTION_FIELDS.has(field)) {
        ignored++;
        continue;
      }
      try {
        const snapshot = snapshotFromWebhookChange(change, field, eventTimeMs);
        if (snapshot.sku !== sku) {
          ignored++;
          continue;
        }
        // A webhook proves the Meta purchase changed, not which 00Widget
        // tenant owns it. Store it unclaimed; the authenticated Graph sync
        // adopts it when that Horizon user next opens the app.
        await recordMetaSubscription(env, snapshot);
        applied++;
      } catch (err) {
        if (err instanceof MetaSubscriptionRejected) {
          console.warn("meta.webhook.change_rejected", { field, reason: err.message });
          ignored++;
          continue;
        }
        throw err;
      }
    }
  }
  return json({ ok: true, applied, ignored });
}

function snapshotFromWebhookChange(
  change: Record<string, unknown>,
  field: string,
  eventTimeMs: number,
) {
  const value = change.value;
  if (!value || typeof value !== "object") {
    throw new MetaSubscriptionRejected("Meta returned an invalid webhook change");
  }
  const envelope = value as Record<string, unknown>;
  const ownerId = typeof envelope.owner_id === "string" ? envelope.owner_id.trim() : "";
  const subscription = envelope.subscription;
  if (!ownerId || !subscription || typeof subscription !== "object") {
    throw new MetaSubscriptionRejected("Meta returned an incomplete webhook change");
  }
  const normalized: Record<string, unknown> = {
    ...(subscription as Record<string, unknown>),
    owner: { id: ownerId },
  };
  if (field === "subscription_canceled") {
    normalized.cancellation_time ??= Math.floor(eventTimeMs / 1_000).toString();
  } else if (field === "subscription_uncanceled") {
    normalized.cancellation_time = null;
    normalized.is_active = true;
  } else if (field === "subscription_expired") {
    normalized.is_active = false;
  } else if (field === "subscription_started" || field === "subscription_renewal_success") {
    normalized.is_active = true;
  }
  return parseMetaSubscriptionSnapshot(normalized, eventTimeMs);
}

async function verifySignature(
  body: string,
  header: string | null,
  secret: string,
): Promise<boolean> {
  if (!header?.startsWith("sha256=")) return false;
  const signature = hexBytes(header.slice("sha256=".length));
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    "HMAC",
    key,
    signature,
    new TextEncoder().encode(body),
  );
}

function hexBytes(value: string): Uint8Array | null {
  if (!/^[0-9a-f]{64}$/i.test(value)) return null;
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < bytes.length; index++) {
    bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function eventTimestamp(value: unknown): number | null {
  const seconds = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  return seconds < 10_000_000_000 ? Math.round(seconds * 1_000) : Math.round(seconds);
}

async function readBodyUpTo(req: Request, maxBytes: number): Promise<string> {
  const contentLength = req.headers.get("content-length")?.trim();
  if (contentLength && /^\d+$/.test(contentLength) && Number(contentLength) > maxBytes) {
    throw new Error("body too large");
  }
  const text = await req.text();
  if (new TextEncoder().encode(text).byteLength > maxBytes) throw new Error("body too large");
  return text;
}
