-- The guest-credential sweep filters on kind and a timestamp, which no existing
-- index covers: api_keys_by_tenant_kind leads with tenant_id and the sweep is
-- tenant-wide, so it fell back to scanning every credential in the deployment
-- on a user-facing request path.
--
-- Partial indexes so only guest rows are indexed at all. Guest tokens never
-- renew, so their expires_at is written once and never updated — this costs
-- nothing on the hot path, unlike a full index on (kind, expires_at) which
-- every sliding-expiry renewal would have to maintain.
CREATE INDEX IF NOT EXISTS api_keys_guest_by_expiry
  ON api_keys(expires_at)
  WHERE kind = 'guest';

CREATE INDEX IF NOT EXISTS api_keys_guest_by_revocation
  ON api_keys(revoked_at)
  WHERE kind = 'guest' AND revoked_at IS NOT NULL;
