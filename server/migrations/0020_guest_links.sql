-- Guest links: a bearer credential bound to exactly one shared resource.
--
-- Modelled as an api_keys row rather than its own table so guest links inherit
-- token hashing, scope checks, expiry, the auth rate limiters, and — the reason
-- that decided it — session revocation. Signing out already revokes every
-- credential sharing a session_id and deletes the registrations tied to those
-- hashes, so a guest link dies with the session that minted it and needs no
-- revocation code of its own.
--
-- Bound to a resource *id*, never a resource kind. Sharing by kind is the
-- documented sharp edge in the existing shares table, where accepting a share
-- for kind "progress" exposes every one of the owner's current and future
-- progress activities.
ALTER TABLE api_keys ADD COLUMN resource_kind TEXT;
ALTER TABLE api_keys ADD COLUMN resource_id TEXT;

-- Listing a tenant's guest links filters on kind before ordering.
CREATE INDEX IF NOT EXISTS api_keys_by_tenant_kind
  ON api_keys(tenant_id, kind, created_at DESC);
