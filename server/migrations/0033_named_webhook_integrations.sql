-- An account may register several named action destinations. The original
-- singular integration becomes the reserved `default` destination so every
-- existing action and every existing API call keeps the same behaviour.
CREATE TABLE webhook_integrations_named (
  tenant_id TEXT NOT NULL,
  webhook_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, webhook_id),
  FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

INSERT INTO webhook_integrations_named
  (tenant_id, webhook_id, api_key_hash, json, updated_at)
SELECT tenant_id, 'default', api_key_hash, json, updated_at
FROM webhook_integrations;

DROP TABLE webhook_integrations;

ALTER TABLE webhook_integrations_named RENAME TO webhook_integrations;

CREATE INDEX webhook_integrations_by_api_key_hash
  ON webhook_integrations(api_key_hash);

-- Routing is publisher-only metadata. It must not appear in cards returned to
-- apps, widgets, or share recipients, for the same reason action payloads are
-- stored outside the public card JSON.
CREATE TABLE action_webhook_routes (
  tenant_id TEXT NOT NULL,
  api_key_hash TEXT NOT NULL,
  card_id TEXT NOT NULL,
  action_id TEXT NOT NULL,
  webhook_id TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (tenant_id, card_id, action_id)
);

CREATE INDEX action_webhook_routes_by_api_key_hash
  ON action_webhook_routes(api_key_hash);
