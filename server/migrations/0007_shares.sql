CREATE TABLE IF NOT EXISTS shares (
  id TEXT PRIMARY KEY,
  owner_tenant_id TEXT NOT NULL,
  recipient_tenant_id TEXT,
  recipient_email TEXT NOT NULL,
  resource_kind TEXT NOT NULL,
  resource_id TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  accepted_at TEXT,
  revoked_at TEXT,
  FOREIGN KEY (owner_tenant_id) REFERENCES tenants(id),
  FOREIGN KEY (recipient_tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS shares_by_owner
  ON shares(owner_tenant_id, status);

CREATE INDEX IF NOT EXISTS shares_by_recipient_tenant
  ON shares(recipient_tenant_id, status);

CREATE INDEX IF NOT EXISTS shares_by_recipient_email
  ON shares(recipient_email, status);

CREATE INDEX IF NOT EXISTS shares_by_resource
  ON shares(owner_tenant_id, resource_kind, resource_id, status);

CREATE TABLE IF NOT EXISTS server_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
