ALTER TABLE widget_tokens
  ADD COLUMN card_ids_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE widget_tokens
  ADD COLUMN all_cards INTEGER NOT NULL DEFAULT 1;

CREATE INDEX widget_tokens_by_tenant_token
  ON widget_tokens(tenant_id, token);
