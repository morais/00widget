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
