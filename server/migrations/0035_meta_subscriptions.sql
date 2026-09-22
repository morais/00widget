-- Meta Horizon Store subscription entitlements.
--
-- Meta identifies the buyer by an app-scoped owner id and the purchase by a
-- stable subscription id. Webhooks can arrive before that owner has connected
-- their Horizon app to a 00Widget tenant, so tenant_id is nullable: the row is
-- recorded first and claimed after the app proves the Meta identity.
CREATE TABLE IF NOT EXISTS meta_subscriptions (
  subscription_id        TEXT PRIMARY KEY,
  owner_id               TEXT NOT NULL,
  tenant_id              TEXT,
  sku                    TEXT NOT NULL,
  is_active              INTEGER NOT NULL DEFAULT 0,
  is_trial               INTEGER NOT NULL DEFAULT 0,
  period_start_ms        INTEGER,
  period_end_ms          INTEGER,
  cancellation_ms        INTEGER,
  next_renewal_ms        INTEGER,
  current_term           TEXT,
  next_term              TEXT,
  -- Meta webhooks carry entry.time. Keeping the newest applied time makes
  -- retries idempotent and stops a delayed cancellation from rewinding a
  -- later renewal or reactivation.
  last_event_ms          INTEGER NOT NULL DEFAULT 0,
  created_at             TEXT NOT NULL,
  updated_at             TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS meta_subscriptions_by_tenant
  ON meta_subscriptions (tenant_id);

CREATE INDEX IF NOT EXISTS meta_subscriptions_by_owner
  ON meta_subscriptions (owner_id);
