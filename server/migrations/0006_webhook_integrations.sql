CREATE TABLE IF NOT EXISTS webhook_integrations (
  tenant_id TEXT PRIMARY KEY,
  api_key_hash TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX IF NOT EXISTS webhook_integrations_by_api_key_hash
  ON webhook_integrations(api_key_hash);
