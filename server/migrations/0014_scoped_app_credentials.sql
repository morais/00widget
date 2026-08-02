ALTER TABLE api_keys ADD COLUMN kind TEXT NOT NULL DEFAULT 'publisher'
  CHECK (kind IN ('publisher', 'app'));
ALTER TABLE api_keys ADD COLUMN session_id TEXT;
ALTER TABLE api_keys ADD COLUMN device_id TEXT;

CREATE INDEX api_keys_by_session
  ON api_keys (tenant_id, session_id)
  WHERE session_id IS NOT NULL;
