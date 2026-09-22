import type { AuthContext } from "./auth";
import { parseJson } from "./cards";
import { badRequest, json } from "./http";
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

  let body: { userAccessToken?: unknown };
  try {
    body = (await parseJson(req, RequestBodyLimits.metaSubscriptionSync)) as {
      userAccessToken?: unknown;
    };
  } catch {
    return badRequest("missing JSON body");
  }
  const userAccessToken = body.userAccessToken;
  if (typeof userAccessToken !== "string" || !userAccessToken.trim()
      || userAccessToken.length > 16 * 1024) {
    return badRequest("userAccessToken must be a non-empty Meta access token");
  }

  const limited = await enforceRateLimits(env, [
    { policy: "subscriptionVerifyTenantHour", key: `tenant:${auth.tenantId}` },
  ]);
  if (limited) return limited;

  try {
    // First use the user token to resolve its app-scoped owner id. Then query
    // again with our own app credentials. That second call is the proof that
    // this owner holds a subscription in *this* Meta app; accepting the first
    // result directly would trust a token minted for an attacker's app with a
    // coincidentally identical SKU.
    const userRows = await queryMetaSubscriptions(userAccessToken.trim(), { sku }, false);
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
    const ownerId = [...ownerIds][0]!;
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
