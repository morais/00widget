import type { AuthContext } from "./auth";
import { parseJson } from "./cards";
import { badRequest, json } from "./http";
import { getHorizonUserForTenant, horizonIdentityEnabled } from "./horizonIdentity";
import {
  claimMetaOwnerForTenant,
  configuredMetaSubscriptionSku,
  isMetaSubscriptionsEnabled,
  MetaSubscriptionRejected,
  parseMetaSubscriptionSnapshot,
  recordMetaSubscription,
} from "./metaSubscription";
import { enforceRateLimits } from "./rateLimit";
import { readSubscriptionState, subscriptionsDisabledResponse } from "./subscription";
import { RequestBodyLimits, type Env } from "./types";

const META_GRAPH_SUBSCRIPTIONS = "https://graph.oculus.com/application/subscriptions";
const META_FIELDS = [
  "id",
  "sku",
  "owner{id}",
  "is_active",
  "is_trial",
  "period_start_time",
  "period_end_time",
  "cancellation_time",
  "next_renewal_time",
  "current_price_term{term,currency,price}",
  "next_price_term{term,currency,price}",
].join(",");

interface MetaGraphPage {
  data?: unknown;
  paging?: { next?: unknown };
}

export async function syncMetaSubscription(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  if (!isMetaSubscriptionsEnabled(env)) return subscriptionsDisabledResponse();
  const appId = (env.META_APP_ID ?? "").trim();
  const appSecret = (env.META_APP_SECRET ?? "").trim();
  const sku = configuredMetaSubscriptionSku(env);
  if (!appId || !appSecret || !sku) {
    console.warn("meta.subscription.not_configured", {
      appId: Boolean(appId),
      appSecret: Boolean(appSecret),
      sku: Boolean(sku),
    });
    return json({ error: "Meta subscriptions are not configured" }, 503);
  }

  let body: { userAccessToken?: unknown; userId?: unknown; sku?: unknown };
  try {
    body = (await parseJson(req, RequestBodyLimits.metaSubscriptionSync)) as {
      userAccessToken?: unknown;
      userId?: unknown;
      sku?: unknown;
    };
  } catch {
    return badRequest("missing JSON body");
  }
  const userAccessToken = typeof body.userAccessToken === "string"
    ? body.userAccessToken.trim()
    : "";
  const userId = typeof body.userId === "string" ? body.userId.trim() : "";
  if (!userAccessToken && !userId) {
    return badRequest("userId or userAccessToken is required");
  }
  if (userAccessToken.length > 16 * 1024) {
    return badRequest("userAccessToken is too long");
  }
  if (userId && (!/^[A-Za-z0-9_-]{1,128}$/.test(userId))) {
    return badRequest("userId is invalid");
  }
  if (userId && auth.credentialKind !== "app") {
    return json({ error: "app credential required" }, 403);
  }
  if (userId && !isConfiguredMetaSku(body.sku, sku)) {
    return badRequest("sku is not a configured Meta subscription product");
  }
  // Once native Horizon identity is enabled, an app-kind bearer credential
  // alone cannot choose which Meta user's purchase to claim. The verified
  // identity bound to its tenant is the owner of this subscription lookup.
  if (userId && horizonIdentityEnabled(env)) {
    const boundUserId = await getHorizonUserForTenant(env, auth.tenantId);
    if (boundUserId !== userId) {
      return json({ error: "Meta user is not linked to this account" }, 403);
    }
  }

  const limited = await enforceRateLimits(env, [
    { policy: "subscriptionVerifyTenantHour", key: `tenant:${auth.tenantId}` },
  ]);
  if (limited) return limited;

  try {
    // Horizon sends the app-scoped Meta user id using an app credential. A
    // user access token is also accepted for older clients; in that case it is
    // used only to discover the owner id. The authoritative lookup is always
    // repeated with our own app credentials, which proves the subscription
    // belongs to this Meta application.
    let ownerId = userId;
    if (!ownerId) {
      const userRows = await queryMetaSubscriptions(userAccessToken, { sku }, false);
      const ownerIds = new Set(userRows.map(ownerIdFromGraphRow).filter(Boolean));
      if (ownerIds.size === 0) {
        return json({
          subscription: await readSubscriptionState(env, auth.tenantId),
          synced: 0,
        });
      }
      if (ownerIds.size !== 1) {
        throw new MetaSubscriptionRejected("Meta returned subscriptions for several owners");
      }
      ownerId = [...ownerIds][0]!;
    }
    const appAccessToken = `OC|${appId}|${appSecret}`;
    const rows = await queryMetaSubscriptions(appAccessToken, { ownerId, sku }, true);
    const fetchedAt = Date.now();
    let synced = 0;
    for (const row of rows) {
      const snapshot = parseMetaSubscriptionSnapshot(row, fetchedAt);
      if (snapshot.ownerId !== ownerId || snapshot.sku !== sku) continue;
      await recordMetaSubscription(env, snapshot, auth.tenantId);
      await claimMetaOwnerForTenant(env, ownerId, auth.tenantId);
      synced++;
    }
    return json({
      subscription: await readSubscriptionState(env, auth.tenantId),
      synced,
    });
  } catch (err) {
    if (err instanceof MetaSubscriptionRejected) {
      return err.status === 400
        ? badRequest(err.message)
        : json({ error: err.message }, err.status);
    }
    throw err;
  }
}

function isConfiguredMetaSku(value: unknown, configuredSku: string): boolean {
  if (typeof value !== "string") return false;
  const requested = value.trim();
  if (requested === configuredSku) return true;
  const prefix = `${configuredSku}:SUBSCRIPTION__`;
  if (!requested.startsWith(prefix)) return false;
  return new Set([
    "WEEKLY",
    "BIWEEKLY",
    "MONTHLY",
    "QUARTERLY",
    "SEMIANNUAL",
    "ANNUAL",
  ]).has(requested.slice(prefix.length));
}

async function queryMetaSubscriptions(
  accessToken: string,
  filters: { ownerId?: string; sku: string },
  usesAppCredentials: boolean,
): Promise<unknown[]> {
  const url = new URL(META_GRAPH_SUBSCRIPTIONS);
  url.searchParams.set("access_token", accessToken);
  url.searchParams.set("fields", META_FIELDS);
  url.searchParams.set("skus", filters.sku);
  if (filters.ownerId) url.searchParams.set("owner_id", filters.ownerId);

  const rows: unknown[] = [];
  let next: string | null = url.toString();
  for (let page = 0; next && page < 10; page++) {
    const current = new URL(next);
    if (current.protocol !== "https:" || current.hostname !== "graph.oculus.com") {
      throw new MetaSubscriptionRejected("Meta returned an invalid pagination URL", 502);
    }
    let response: Response;
    try {
      response = await fetch(current.toString(), {
        headers: { accept: "application/json" },
      });
    } catch {
      throw new MetaSubscriptionRejected("Meta subscription verification is unavailable", 502);
    }
    if (!response.ok) {
      throw new MetaSubscriptionRejected(
        response.status >= 500 || usesAppCredentials
          ? "Meta subscription verification is unavailable"
          : "Meta could not verify this account",
        response.status >= 500 || usesAppCredentials ? 502 : 400,
      );
    }
    let payload: MetaGraphPage;
    try {
      payload = await response.json() as MetaGraphPage;
    } catch {
      throw new MetaSubscriptionRejected("Meta returned an invalid response", 502);
    }
    if (!Array.isArray(payload.data)) {
      throw new MetaSubscriptionRejected("Meta returned an invalid response", 502);
    }
    rows.push(...payload.data);
    next = typeof payload.paging?.next === "string" ? payload.paging.next : null;
  }
  if (next) throw new MetaSubscriptionRejected("Meta returned too many subscription pages", 502);
  return rows;
}

function ownerIdFromGraphRow(row: unknown): string | null {
  if (!row || typeof row !== "object") return null;
  const owner = (row as Record<string, unknown>).owner;
  if (!owner || typeof owner !== "object") return null;
  const id = (owner as Record<string, unknown>).id;
  return typeof id === "string" && id.trim() ? id.trim() : null;
}
