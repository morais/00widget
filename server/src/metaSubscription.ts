import type { SubscriptionState } from "./subscription";
import type { Env } from "./types";

export interface MetaSubscriptionRow {
  subscription_id: string;
  owner_id: string;
  tenant_id: string | null;
  sku: string;
  is_active: number;
  is_trial: number;
  period_start_ms: number | null;
  period_end_ms: number | null;
  cancellation_ms: number | null;
  next_renewal_ms: number | null;
  current_term: string | null;
  next_term: string | null;
  last_event_ms: number;
}

export interface MetaSubscriptionAdminRow extends MetaSubscriptionRow {
  created_at: string;
  updated_at: string;
}

export interface MetaSubscriptionSnapshot {
  subscriptionId: string;
  ownerId: string;
  sku: string;
  isActive: boolean;
  isTrial: boolean;
  periodStartMs: number | null;
  periodEndMs: number | null;
  cancellationMs: number | null;
  nextRenewalMs: number | null;
  currentTerm: string | null;
  nextTerm: string | null;
  eventTimeMs: number;
}

export class MetaSubscriptionRejected extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
    this.name = "MetaSubscriptionRejected";
  }
}

export function configuredMetaSubscriptionSku(env: Env): string | null {
  const value = (env.META_SUBSCRIPTION_SKU ?? "").trim();
  return value || null;
}

export function isMetaSubscriptionsEnabled(env: Env): boolean {
  return (env.META_SUBSCRIPTIONS_ENABLED ?? "").trim().toLowerCase() === "true"
    && configuredMetaSubscriptionSku(env) !== null;
}

export function evaluateMetaSubscription(row: MetaSubscriptionRow | null): SubscriptionState {
  if (!row) return { status: "none", active: false };

  const base: SubscriptionState = {
    status: "expired",
    active: false,
    provider: "meta",
    productId: row.sku,
    expiresAt: row.period_end_ms
      ? new Date(row.period_end_ms).toISOString()
      : undefined,
    // A cancellation preserves access through the paid period but stops the
    // next renewal. Meta keeps is_active true until that period actually ends.
    autoRenew: row.cancellation_ms === null,
  };
  if (row.is_active !== 1) return base;
  return {
    ...base,
    status: row.is_trial === 1 ? "trial" : "active",
    active: true,
  };
}

export async function readMetaSubscriptionRow(
  env: Env,
  tenantId: string,
): Promise<MetaSubscriptionRow | null> {
  const sku = configuredMetaSubscriptionSku(env);
  if (!isMetaSubscriptionsEnabled(env) || !sku) return null;
  return env.ZW_DB.prepare(
    `SELECT subscription_id, owner_id, tenant_id, sku, is_active, is_trial,
            period_start_ms, period_end_ms, cancellation_ms, next_renewal_ms,
            current_term, next_term, last_event_ms
     FROM meta_subscriptions
     WHERE tenant_id = ? AND sku = ?
     ORDER BY is_active DESC, COALESCE(period_end_ms, 0) DESC
     LIMIT 1`,
  )
    .bind(tenantId, sku)
    .first<MetaSubscriptionRow>();
}

export async function readMetaSubscriptionState(
  env: Env,
  tenantId: string,
): Promise<SubscriptionState> {
  return evaluateMetaSubscription(await readMetaSubscriptionRow(env, tenantId));
}

export async function listMetaSubscriptionRowsForTenant(
  env: Env,
  tenantId: string,
): Promise<MetaSubscriptionAdminRow[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT subscription_id, owner_id, tenant_id, sku, is_active, is_trial,
            period_start_ms, period_end_ms, cancellation_ms, next_renewal_ms,
            current_term, next_term, last_event_ms, created_at, updated_at
     FROM meta_subscriptions
     WHERE tenant_id = ?
     ORDER BY is_active DESC, COALESCE(period_end_ms, 0) DESC`,
  )
    .bind(tenantId)
    .all<MetaSubscriptionAdminRow>();
  return rows.results;
}

export function parseMetaSubscriptionSnapshot(
  value: unknown,
  eventTimeMs: number,
): MetaSubscriptionSnapshot {
  if (!value || typeof value !== "object") {
    throw new MetaSubscriptionRejected("Meta returned an invalid subscription");
  }
  const input = value as Record<string, unknown>;
  const owner = input.owner;
  const ownerId = owner && typeof owner === "object"
    ? stringField(owner as Record<string, unknown>, "id")
    : null;
  const subscriptionId = stringField(input, "id");
  const sku = stringField(input, "sku");
  if (!subscriptionId || !ownerId || !sku || typeof input.is_active !== "boolean") {
    throw new MetaSubscriptionRejected("Meta returned an incomplete subscription");
  }
  return {
    subscriptionId,
    ownerId,
    sku,
    isActive: input.is_active,
    isTrial: input.is_trial === true,
    periodStartMs: metaTimestamp(input.period_start_time),
    periodEndMs: metaTimestamp(input.period_end_time),
    cancellationMs: metaTimestamp(input.cancellation_time),
    nextRenewalMs: metaTimestamp(input.next_renewal_time),
    // Renewal webhook examples use current_offer/next_offer while the status
    // endpoint uses current_price_term/next_price_term. They carry the same
    // shape; accepting both keeps one canonical row regardless of source.
    currentTerm: priceTerm(input.current_price_term ?? input.current_offer),
    nextTerm: priceTerm(input.next_price_term ?? input.next_offer),
    eventTimeMs,
  };
}

export async function recordMetaSubscription(
  env: Env,
  snapshot: MetaSubscriptionSnapshot,
  tenantId?: string,
): Promise<void> {
  const now = new Date().toISOString();
  await env.ZW_DB.prepare(
    `INSERT INTO meta_subscriptions
       (subscription_id, owner_id, tenant_id, sku, is_active, is_trial,
        period_start_ms, period_end_ms, cancellation_ms, next_renewal_ms,
        current_term, next_term, last_event_ms, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (subscription_id) DO UPDATE SET
       owner_id = excluded.owner_id,
       tenant_id = COALESCE(meta_subscriptions.tenant_id, excluded.tenant_id),
       sku = excluded.sku,
       is_active = excluded.is_active,
       is_trial = excluded.is_trial,
       period_start_ms = excluded.period_start_ms,
       period_end_ms = excluded.period_end_ms,
       cancellation_ms = excluded.cancellation_ms,
       next_renewal_ms = excluded.next_renewal_ms,
       current_term = excluded.current_term,
       next_term = excluded.next_term,
       last_event_ms = excluded.last_event_ms,
       updated_at = excluded.updated_at
     WHERE excluded.last_event_ms >= meta_subscriptions.last_event_ms`,
  )
    .bind(
      snapshot.subscriptionId,
      snapshot.ownerId,
      tenantId ?? null,
      snapshot.sku,
      snapshot.isActive ? 1 : 0,
      snapshot.isTrial ? 1 : 0,
      snapshot.periodStartMs,
      snapshot.periodEndMs,
      snapshot.cancellationMs,
      snapshot.nextRenewalMs,
      snapshot.currentTerm,
      snapshot.nextTerm,
      snapshot.eventTimeMs,
      now,
      now,
    )
    .run();
}

export async function claimMetaOwnerForTenant(
  env: Env,
  ownerId: string,
  tenantId: string,
): Promise<void> {
  const existing = await env.ZW_DB.prepare(
    `SELECT DISTINCT tenant_id
     FROM meta_subscriptions
     WHERE owner_id = ? AND tenant_id IS NOT NULL`,
  )
    .bind(ownerId)
    .all<{ tenant_id: string }>();
  if (existing.results.some((row) => row.tenant_id !== tenantId)) {
    throw new MetaSubscriptionRejected("this Meta subscription is already linked to another account");
  }
  await env.ZW_DB.prepare(
    `UPDATE meta_subscriptions
     SET tenant_id = ?, updated_at = ?
     WHERE owner_id = ? AND tenant_id IS NULL`,
  )
    .bind(tenantId, new Date().toISOString(), ownerId)
    .run();

  // Re-read after the conditional update. Two tenants can try to claim a new
  // webhook row concurrently; only one wins, and the loser must learn that it
  // did rather than returning success from its stale preflight read.
  const claimed = await env.ZW_DB.prepare(
    `SELECT DISTINCT tenant_id
     FROM meta_subscriptions
     WHERE owner_id = ? AND tenant_id IS NOT NULL`,
  )
    .bind(ownerId)
    .all<{ tenant_id: string }>();
  if (claimed.results.some((row) => row.tenant_id !== tenantId)) {
    throw new MetaSubscriptionRejected("this Meta subscription is already linked to another account");
  }
}

function stringField(input: Record<string, unknown>, key: string): string | null {
  const value = input[key];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function metaTimestamp(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value < 10_000_000_000 ? value * 1_000 : value;
  }
  if (typeof value !== "string" || !value.trim()) return null;
  if (/^\d+$/.test(value.trim())) {
    const number = Number(value);
    return number < 10_000_000_000 ? number * 1_000 : number;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function priceTerm(value: unknown): string | null {
  if (!value || typeof value !== "object") return null;
  return stringField(value as Record<string, unknown>, "term");
}
