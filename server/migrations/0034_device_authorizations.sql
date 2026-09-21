-- Short-lived OAuth Device Authorization Grants used by the Horizon OS app.
--
-- The URL delivered through Horizon's send_auth_url carries only the short,
-- human-readable user code. The headset alone holds the high-entropy device
-- code and polls with it. Both are hashed here so neither bearer value is
-- recoverable from a database read.
CREATE TABLE IF NOT EXISTS device_authorizations (
  id TEXT PRIMARY KEY,
  device_code_hash TEXT NOT NULL UNIQUE,
  user_code_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'denied', 'consuming', 'consumed')),
  tenant_id TEXT,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  approved_at TEXT,
  consumed_at TEXT,
  FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

-- No expires_at index: this table is looked up by one of its two unique code
-- hashes, and expiry cleanup is a bounded opportunistic sweep. Indexing expiry
-- would add a fourth index write to every authorization for a background job
-- that normally has only a handful of rows to inspect.
