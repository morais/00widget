ALTER TABLE api_keys
  ADD COLUMN scopes_json TEXT NOT NULL DEFAULT '[]';

-- Existing publisher credentials retain their prior capabilities until their
-- normal 90-day expiry. Every new credential is issued from a least-privilege
-- preset, so compatibility does not require an outage or emergency rotation.
UPDATE api_keys
SET scopes_json = '["tenant:read","publish","device:register","actions:run","shares:manage","webhook:manage"]'
WHERE kind = 'publisher';

UPDATE api_keys
SET scopes_json = '["actions:confirm","shares:manage"]'
WHERE kind = 'app';
