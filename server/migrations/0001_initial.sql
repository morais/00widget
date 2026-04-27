CREATE TABLE IF NOT EXISTS cards (
  tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  id TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, id)
);

CREATE INDEX IF NOT EXISTS cards_by_tenant_updated
  ON cards(tenant_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS cards_by_api_key_hash
  ON cards(api_key_hash);

CREATE TABLE IF NOT EXISTS devices (
  tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  device_id TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, device_id)
);

CREATE INDEX IF NOT EXISTS devices_by_api_key_hash
  ON devices(api_key_hash);

CREATE TABLE IF NOT EXISTS widget_tokens (
  tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  device_id TEXT NOT NULL,
  widget_kind TEXT NOT NULL,
  token TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, device_id, widget_kind)
);

CREATE INDEX IF NOT EXISTS widget_tokens_by_tenant
  ON widget_tokens(tenant_id);

CREATE INDEX IF NOT EXISTS widget_tokens_by_api_key_hash
  ON widget_tokens(api_key_hash);

CREATE TABLE IF NOT EXISTS activities (
  tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  external_id TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, external_id)
);

CREATE INDEX IF NOT EXISTS activities_by_api_key_hash
  ON activities(api_key_hash);

CREATE TABLE IF NOT EXISTS pending_activities (
  tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  external_id TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, external_id)
);

CREATE INDEX IF NOT EXISTS pending_activities_by_api_key_hash
  ON pending_activities(api_key_hash);

CREATE TABLE IF NOT EXISTS start_tokens (
  tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  device_id TEXT NOT NULL,
  attributes_type TEXT NOT NULL,
  token TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, device_id, attributes_type)
);

CREATE INDEX IF NOT EXISTS start_tokens_by_tenant_type
  ON start_tokens(tenant_id, attributes_type);

CREATE INDEX IF NOT EXISTS start_tokens_by_api_key_hash
  ON start_tokens(api_key_hash);
