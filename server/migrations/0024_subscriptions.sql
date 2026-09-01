-- App Store subscription entitlements.
--
-- Keyed by original_transaction_id rather than tenant_id, with tenant_id
-- nullable, for two reasons that both come from how Apple delivers this data:
--
--   * App Store Server Notifications carry only originalTransactionId. A
--     renewal or cancellation for a purchase whose client-side verification
--     never landed (app killed, offline, reinstall) would otherwise have
--     nowhere to go. Here it lands as an unclaimed row and is adopted the next
--     time the app verifies.
--   * originalTransactionId identifies an App Store account; tenant_id
--     identifies a Sign in with Apple identity. They usually coincide and are
--     not required to. The primary key is what stops one purchase from
--     entitling several tenants.
--
-- Rows are written on purchase, renewal, and status change — a handful of
-- writes per subscriber per year. That is why tenant_id carries an index
-- despite D1 billing index maintenance as rows written: unlike
-- rate_limit_buckets, this table is not on any hot write path, and the index
-- is what makes the per-request entitlement lookup a seek.
CREATE TABLE IF NOT EXISTS subscriptions (
  original_transaction_id TEXT PRIMARY KEY,
  tenant_id               TEXT,
  product_id              TEXT NOT NULL,
  status                  TEXT NOT NULL,
  -- Milliseconds since the epoch, as Apple sends them. Stored unconverted so a
  -- row can be compared against Apple's own payloads without a round trip
  -- through string formatting.
  expires_at_ms           INTEGER,
  -- Apple's billing grace period, when one is configured in App Store Connect.
  -- Distinct from the deployment's own SUBSCRIPTION_GRACE_DAYS, which is
  -- applied at read time and never stored.
  grace_expires_at_ms     INTEGER,
  is_trial                INTEGER NOT NULL DEFAULT 0,
  auto_renew              INTEGER NOT NULL DEFAULT 1,
  -- "Sandbox" or "Production". Sandbox purchases are accepted only by an
  -- explicit deployment opt-in, and entitlement reads filter on that current
  -- policy. The value remains stored after the opt-in is removed for audit.
  environment             TEXT NOT NULL,
  revoked_at_ms           INTEGER,
  -- Apple's signedDate for the most recent payload applied to this row. Used
  -- to drop out-of-order notifications, which Apple does not guarantee the
  -- ordering of.
  signed_date_ms          INTEGER NOT NULL DEFAULT 0,
  created_at              TEXT NOT NULL,
  updated_at              TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS subscriptions_by_tenant
  ON subscriptions (tenant_id);
