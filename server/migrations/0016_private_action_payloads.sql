CREATE TABLE action_payloads (
  tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  card_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, card_id, action_id)
);

CREATE INDEX action_payloads_by_api_key_hash
  ON action_payloads (api_key_hash);

-- Move payloads out of existing public card JSON before any updated app or
-- share recipient can fetch it again.
INSERT OR REPLACE INTO action_payloads
  (tenant_id, api_key_hash, card_id, action_id, json, updated_at)
SELECT
  cards.tenant_id,
  cards.api_key_hash,
  cards.id,
  json_extract(action.value, '$.id'),
  json_extract(action.value, '$.payload'),
  cards.updated_at
FROM cards, json_each(cards.json, '$.actions') AS action
WHERE json_type(action.value, '$.id') = 'text'
  AND json_type(action.value, '$.payload') = 'object';

UPDATE cards
SET json = json_set(
  json,
  '$.actions',
  json((
    SELECT json_group_array(json_remove(action.value, '$.payload'))
    FROM json_each(cards.json, '$.actions') AS action
  ))
)
WHERE json_type(json, '$.actions') = 'array'
  AND EXISTS (
    SELECT 1
    FROM json_each(cards.json, '$.actions') AS action
    WHERE json_type(action.value, '$.payload') = 'object'
  );
