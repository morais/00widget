-- Redeemed MCP authorization codes, so one code mints exactly one credential.
--
-- Authorization codes are HMAC-signed values rather than rows (see mcpOAuth.ts)
-- because an OAuth code table is pure write traffic that then has to be swept,
-- and D1 bills a row written at 1000x a row read. That reasoning holds for
-- *issuing*: a code is minted on every authorize, and nothing needs to remember
-- one that is never redeemed.
--
-- It does not hold for redeeming. A signed code cannot be marked used, so
-- single-use rested on a 60-second lifetime plus PKCE — and every redemption
-- called createApiKey, so anything holding both code and verifier could mint
-- credentials repeatedly, and an ordinary client retry silently accumulated
-- full 90-day publisher tokens on the operator's account.
--
-- The write volume this adds is one row per successful token exchange, which
-- mcpTokenIpHour already caps at 30 per hour per IP. That is nothing like the
-- rate limiter's traffic, and it buys the property the signature cannot.
--
-- No index beyond the primary key: every read is a point lookup on jti, and the
-- sweep deletes by rowid rather than scanning expires_at, for the same reason
-- rate_limit_buckets carries no index on its own expiry.
CREATE TABLE IF NOT EXISTS mcp_authorization_codes (
  jti TEXT PRIMARY KEY,
  redeemed_at TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
