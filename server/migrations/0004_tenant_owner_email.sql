ALTER TABLE tenants ADD COLUMN owner_email TEXT;

CREATE INDEX IF NOT EXISTS tenants_by_owner_email
  ON tenants(owner_email);
