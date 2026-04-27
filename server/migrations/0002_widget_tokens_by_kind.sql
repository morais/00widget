CREATE INDEX IF NOT EXISTS widget_tokens_by_tenant_kind
  ON widget_tokens(tenant_id, widget_kind, device_id);
