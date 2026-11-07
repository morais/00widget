-- Native Horizon credentials have a different shape from the Apple app's
-- paired session. A recorded use proves that issuance completed and the app
-- authenticated afterwards. Keep expired/revoked historical evidence, require
-- the current Horizon account binding, and preserve an existing first marker.
UPDATE tenants
SET first_native_sign_in_at = (
  SELECT MIN(k.created_at)
  FROM api_keys k JOIN horizon_accounts h ON h.tenant_id = k.tenant_id
  WHERE k.tenant_id = tenants.id AND k.kind = 'app' AND k.purpose = 'device'
    AND k.last_used_at IS NOT NULL AND k.last_used_at <> ''
)
WHERE first_native_sign_in_at IS NULL
  AND EXISTS (
    SELECT 1 FROM api_keys k JOIN horizon_accounts h ON h.tenant_id = k.tenant_id
    WHERE k.tenant_id = tenants.id AND k.kind = 'app' AND k.purpose = 'device'
      AND k.last_used_at IS NOT NULL AND k.last_used_at <> ''
  );
