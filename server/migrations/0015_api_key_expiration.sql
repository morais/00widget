ALTER TABLE api_keys ADD COLUMN expires_at TEXT;

UPDATE api_keys
SET expires_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+90 days')
WHERE expires_at IS NULL;

CREATE INDEX api_keys_by_expiration
  ON api_keys (expires_at)
  WHERE revoked_at IS NULL;
