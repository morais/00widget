CREATE TABLE activity_instances (
  id TEXT PRIMARY KEY,
  owner_tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  external_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (owner_tenant_id, external_id)
);

CREATE INDEX activity_instances_by_owner_kind
  ON activity_instances (owner_tenant_id, kind);

CREATE INDEX activity_instances_by_api_key_hash
  ON activity_instances (api_key_hash);

CREATE TABLE activity_targets (
  activity_instance_id TEXT NOT NULL,
  owner_tenant_id TEXT NOT NULL,
  target_tenant_id TEXT NOT NULL,
  share_id TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (activity_instance_id, target_tenant_id)
);

CREATE INDEX activity_targets_by_target
  ON activity_targets (target_tenant_id, activity_instance_id);

CREATE INDEX activity_targets_by_share
  ON activity_targets (share_id);

CREATE TABLE activity_deliveries (
  activity_instance_id TEXT NOT NULL,
  owner_tenant_id TEXT NOT NULL,
  target_tenant_id TEXT NOT NULL,
  share_id TEXT,
  api_key_hash TEXT NOT NULL,
  device_id TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (activity_instance_id, target_tenant_id, device_id)
);

CREATE INDEX activity_deliveries_by_target
  ON activity_deliveries (target_tenant_id, activity_instance_id);

CREATE INDEX activity_deliveries_by_share
  ON activity_deliveries (share_id);

CREATE INDEX activity_deliveries_by_api_key_hash
  ON activity_deliveries (api_key_hash);

-- Preserve owner-local pending instances. Synthetic `share:<id>` hashes mark
-- legacy recipient mirrors and are migrated separately with share provenance.
WITH generated AS (
  SELECT
    'legacy:' || lower(hex(randomblob(16))) AS instance_id,
    tenant_id,
    api_key_hash,
    external_id,
    COALESCE(json_extract(json, '$.kind'), 'generic') AS kind,
    json,
    updated_at
  FROM pending_activities
  WHERE api_key_hash NOT LIKE 'share:%'
)
INSERT OR IGNORE INTO activity_instances
  (id, owner_tenant_id, api_key_hash, external_id, kind, json, updated_at)
SELECT
  instance_id,
  tenant_id,
  api_key_hash,
  external_id,
  kind,
  json_set(json, '$.activityInstanceId', instance_id),
  updated_at
FROM generated;

-- Preserve owner-local registered activities that have no pending row.
WITH source AS (
  SELECT activities.*
  FROM activities
  WHERE api_key_hash NOT LIKE 'share:%'
    AND device_id = (
      SELECT MIN(candidate.device_id)
      FROM activities AS candidate
      WHERE candidate.tenant_id = activities.tenant_id
        AND candidate.external_id = activities.external_id
    )
), generated AS (
  SELECT
    'legacy:' || lower(hex(randomblob(16))) AS instance_id,
    tenant_id,
    api_key_hash,
    external_id,
    COALESCE(json_extract(json, '$.kind'), 'generic') AS kind,
    COALESCE(json_extract(json, '$.title'), external_id) AS title,
    COALESCE(json_extract(json, '$.lastState.state'), 'unknown') AS state,
    COALESCE(json_extract(json, '$.lastState.updatedAt'), updated_at) AS state_updated_at,
    updated_at
  FROM source
)
INSERT OR IGNORE INTO activity_instances
  (id, owner_tenant_id, api_key_hash, external_id, kind, json, updated_at)
SELECT
  instance_id,
  tenant_id,
  api_key_hash,
  external_id,
  kind,
  json_object(
    'activityInstanceId', instance_id,
    'externalActivityId', external_id,
    'kind', kind,
    'title', title,
    'state', state,
    'updatedAt', state_updated_at
  ),
  updated_at
FROM generated;

-- Reconnect legacy mirrors that still retain their `share:<id>` marker to the
-- owner's canonical instance. Rows whose provenance was already lost are
-- intentionally treated as recipient-owned above: that is fail-closed and
-- prevents a former owner from targeting them after this migration.
WITH shared_pending AS (
  SELECT
    shares.owner_tenant_id,
    shares.id AS share_id,
    pending_activities.api_key_hash,
    pending_activities.external_id,
    pending_activities.json,
    pending_activities.updated_at,
    COALESCE(json_extract(pending_activities.json, '$.kind'), 'generic') AS kind
  FROM pending_activities
  JOIN shares ON shares.id = substr(pending_activities.api_key_hash, 7)
  WHERE pending_activities.api_key_hash LIKE 'share:%'
), generated AS (
  SELECT *, 'legacy:' || lower(hex(randomblob(16))) AS instance_id
  FROM shared_pending
)
INSERT OR IGNORE INTO activity_instances
  (id, owner_tenant_id, api_key_hash, external_id, kind, json, updated_at)
SELECT
  instance_id,
  owner_tenant_id,
  api_key_hash,
  external_id,
  kind,
  json_set(json, '$.activityInstanceId', instance_id),
  updated_at
FROM generated;

INSERT OR IGNORE INTO activity_targets
  (activity_instance_id, owner_tenant_id, target_tenant_id, share_id, created_at)
SELECT id, owner_tenant_id, owner_tenant_id, NULL, updated_at
FROM activity_instances;

INSERT OR REPLACE INTO activity_targets
  (activity_instance_id, owner_tenant_id, target_tenant_id, share_id, created_at)
SELECT
  instances.id,
  instances.owner_tenant_id,
  pending_activities.tenant_id,
  shares.id,
  pending_activities.updated_at
FROM pending_activities
JOIN shares ON shares.id = substr(pending_activities.api_key_hash, 7)
JOIN activity_instances AS instances
  ON instances.owner_tenant_id = shares.owner_tenant_id
 AND instances.external_id = pending_activities.external_id
WHERE pending_activities.api_key_hash LIKE 'share:%';

INSERT OR REPLACE INTO activity_targets
  (activity_instance_id, owner_tenant_id, target_tenant_id, share_id, created_at)
SELECT
  instances.id,
  instances.owner_tenant_id,
  activities.tenant_id,
  shares.id,
  activities.updated_at
FROM activities
JOIN shares ON shares.id = substr(activities.api_key_hash, 7)
JOIN activity_instances AS instances
  ON instances.owner_tenant_id = shares.owner_tenant_id
 AND instances.external_id = activities.external_id
WHERE activities.api_key_hash LIKE 'share:%';

INSERT OR REPLACE INTO activity_deliveries
  (activity_instance_id, owner_tenant_id, target_tenant_id, share_id,
   api_key_hash, device_id, json, updated_at)
SELECT
  instances.id,
  activities.tenant_id,
  activities.tenant_id,
  NULL,
  activities.api_key_hash,
  activities.device_id,
  activities.json,
  activities.updated_at
FROM activities
JOIN activity_instances AS instances
  ON instances.owner_tenant_id = activities.tenant_id
 AND instances.external_id = activities.external_id
WHERE activities.api_key_hash NOT LIKE 'share:%';

INSERT OR REPLACE INTO activity_deliveries
  (activity_instance_id, owner_tenant_id, target_tenant_id, share_id,
   api_key_hash, device_id, json, updated_at)
SELECT
  instances.id,
  shares.owner_tenant_id,
  activities.tenant_id,
  shares.id,
  activities.api_key_hash,
  activities.device_id,
  activities.json,
  activities.updated_at
FROM activities
JOIN shares ON shares.id = substr(activities.api_key_hash, 7)
JOIN activity_instances AS instances
  ON instances.owner_tenant_id = shares.owner_tenant_id
 AND instances.external_id = activities.external_id
WHERE activities.api_key_hash LIKE 'share:%';

DROP TABLE activities;
DROP TABLE pending_activities;
