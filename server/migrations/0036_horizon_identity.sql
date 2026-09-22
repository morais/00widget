-- A Meta user ID is scoped to the Horizon app, not an email address. Keep it
-- separate from a tenant's optional owner email and give each identity one
-- tenant. The tenant constraint also prevents a second headset user from
-- silently joining an account that already has a Horizon owner.
CREATE TABLE IF NOT EXISTS horizon_accounts (
  app_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  tenant_id TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  PRIMARY KEY (app_id, user_id),
  FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

-- A proof issued by the Meta SDK is a bearer assertion. Refuse a second use
-- of the same nonce, including a second login attempt while it is still live.
CREATE TABLE IF NOT EXISTS horizon_proof_uses (
  nonce_hash TEXT PRIMARY KEY,
  expires_at TEXT NOT NULL
);

-- An identity-bound device code links the headset's verified Meta identity
-- to the Apple account whose owner approves it. Legacy codes leave these
-- columns NULL and keep their original phone-assisted behavior.
ALTER TABLE device_authorizations ADD COLUMN horizon_app_id TEXT;
ALTER TABLE device_authorizations ADD COLUMN horizon_user_id TEXT;
