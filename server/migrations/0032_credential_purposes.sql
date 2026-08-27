-- A publisher credential can be the app's device half, a token copied from
-- Agent config, an MCP connector, or a manually managed key. Session membership
-- used to be the only distinction, which made signing one device out revoke
-- the Agent-config token created beside it. Purpose is deliberately not
-- indexed: an account holds a handful of credentials, and every index on this
-- table multiplies the cost of issuing and renewing them.
ALTER TABLE api_keys ADD COLUMN purpose TEXT NOT NULL DEFAULT 'general'
  CHECK (purpose IN ('general', 'device', 'app', 'agent', 'connector', 'guest'));

-- Backfill credentials issued before purpose was explicit. Full publisher
-- tokens are the tokens shown by Agent config; MCP credentials deliberately
-- omit webhook:manage, while device credentials carry device:register.
UPDATE api_keys
SET purpose = CASE
  WHEN kind = 'app' THEN 'app'
  WHEN kind = 'guest' THEN 'guest'
  WHEN kind = 'publisher' AND instr(scopes_json, '"webhook:manage"') > 0 THEN 'agent'
  WHEN kind = 'publisher' AND instr(scopes_json, '"device:register"') > 0 THEN 'device'
  WHEN kind = 'publisher' AND label LIKE 'MCP · %' THEN 'connector'
  ELSE 'general'
END;

-- Agent tokens and guest links belong to the account, not to the phone whose
-- UI happened to mint them. Existing rows must leave the old device session or
-- the first sign-out after this migration would still revoke them.
UPDATE api_keys
SET session_id = NULL, device_id = NULL
WHERE purpose IN ('agent', 'guest');
