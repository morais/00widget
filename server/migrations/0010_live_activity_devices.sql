CREATE TABLE activities_by_device (
  tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  external_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, external_id, device_id)
);

INSERT INTO activities_by_device
  (tenant_id, api_key_hash, external_id, device_id, json, updated_at)
SELECT
  tenant_id,
  api_key_hash,
  external_id,
  COALESCE(json_extract(json, '$.deviceId'), 'legacy'),
  json,
  updated_at
FROM activities;

DROP TABLE activities;
ALTER TABLE activities_by_device RENAME TO activities;

CREATE INDEX activities_by_api_key_hash
  ON activities(api_key_hash);

CREATE INDEX activities_by_external_id
  ON activities(tenant_id, external_id);
