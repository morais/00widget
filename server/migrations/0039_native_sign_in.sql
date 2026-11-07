ALTER TABLE tenants ADD COLUMN first_native_sign_in_at TEXT;

-- Apple identities are also written by browser signup. Neither those rows,
-- credential labels, subscriptions nor push tokens prove a native sign-in.
-- Only the native Apple/reviewer login issues this paired device/app session.
-- Retain revoked/expired evidence: signing out does not undo having signed in.
-- This is the earliest surviving evidence, not a reconstruction of lost history.
UPDATE tenants
SET first_native_sign_in_at = (
  SELECT MIN(app.created_at)
  FROM api_keys device
  JOIN api_keys app ON app.tenant_id = device.tenant_id
    AND app.session_id = device.session_id
  WHERE device.tenant_id = tenants.id
    AND device.kind = 'publisher' AND device.purpose = 'device'
    AND device.session_id IS NOT NULL AND device.session_id <> ''
    AND app.kind = 'app' AND app.purpose = 'app'
)
WHERE first_native_sign_in_at IS NULL
  AND EXISTS (
    SELECT 1 FROM api_keys device
    JOIN api_keys app ON app.tenant_id = device.tenant_id
      AND app.session_id = device.session_id
    WHERE device.tenant_id = tenants.id
      AND device.kind = 'publisher' AND device.purpose = 'device'
      AND device.session_id IS NOT NULL AND device.session_id <> ''
      AND app.kind = 'app' AND app.purpose = 'app'
  );
