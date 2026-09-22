-- Browser sign-in for Horizon-only accounts. The browser keeps the random
-- secret in an HttpOnly cookie; the headset sees only the short approval code.
-- Both values are stored hashed and expire after ten minutes.
CREATE TABLE IF NOT EXISTS horizon_browser_logins (
  id TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL UNIQUE,
  browser_hash TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'denied', 'consumed')),
  app_id TEXT,
  user_id TEXT,
  tenant_id TEXT,
  next_path TEXT,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);
