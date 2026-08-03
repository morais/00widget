-- Sliding expiration for API keys.
--
-- `expires_at` alone forces a synchronized re-key of every agent holding a
-- token, which in practice means the secret gets re-copied into more places
-- than it would have leaked from. `renew_seconds` turns the deadline into an
-- idle timeout instead: a credential in active use extends itself on the
-- existing row, so the token *value* never changes and nothing downstream has
-- to be re-keyed. A credential that goes quiet still expires, which is the case
-- expiry actually exists for — a token left behind in an archived repo or a
-- decommissioned CI job.
--
-- NULL means "fixed deadline, never extend", so it stays the safe default for
-- any key an operator deliberately wants short-lived.
ALTER TABLE api_keys ADD COLUMN renew_seconds INTEGER;

-- Existing live credentials adopt the 90-day window they were already issued
-- with. Revoked keys are left alone: renewal only ever happens on a successful
-- authentication, which they can no longer reach.
UPDATE api_keys
SET renew_seconds = 90 * 24 * 60 * 60
WHERE renew_seconds IS NULL AND revoked_at IS NULL;
