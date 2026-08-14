-- 0014 constrained api_keys.kind to ('publisher', 'app'). 0020 added guest
-- links as a third kind and missed it, so every attempt to mint one failed
-- with "CHECK constraint failed" and surfaced as a 500. The unit suite did not
-- catch it because FakeD1 enforces no constraints; it now rejects unknown
-- kinds for exactly this reason.
--
-- SQLite cannot alter a CHECK constraint, so widening it means rebuilding the
-- table. Every other column, default and index is preserved verbatim.
CREATE TABLE api_keys_new (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT,
  revoked_at TEXT,
  kind TEXT NOT NULL DEFAULT 'publisher'
    CHECK (kind IN ('publisher', 'app', 'guest')),
  session_id TEXT,
  device_id TEXT,
  expires_at TEXT,
  scopes_json TEXT NOT NULL DEFAULT '[]',
  renew_seconds INTEGER,
  resource_kind TEXT,
  resource_id TEXT,
  FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

INSERT INTO api_keys_new
  (id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at, kind,
   session_id, device_id, expires_at, scopes_json, renew_seconds, resource_kind, resource_id)
SELECT
   id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at, kind,
   session_id, device_id, expires_at, scopes_json, renew_seconds, resource_kind, resource_id
FROM api_keys;

DROP TABLE api_keys;
ALTER TABLE api_keys_new RENAME TO api_keys;

-- Indexes go with the dropped table and have to come back.
CREATE INDEX IF NOT EXISTS api_keys_by_tenant
  ON api_keys(tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS api_keys_by_token_hash
  ON api_keys(token_hash);
CREATE INDEX IF NOT EXISTS api_keys_by_session
  ON api_keys (tenant_id, session_id)
  WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS api_keys_by_expiration
  ON api_keys (expires_at)
  WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS api_keys_by_tenant_kind
  ON api_keys(tenant_id, kind, created_at DESC);
