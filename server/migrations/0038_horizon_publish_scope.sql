-- Horizon is a first-party account surface and exposes the same explicit card
-- deletion and Live Activity ending controls as iOS. Those routes require the
-- publish scope. Upgrade already-issued headset credentials in place so the
-- controls start working after deployment without forcing every user to sign
-- out and back in. The fixed label, app kind, and device purpose together are
-- assigned only by the two Horizon credential issuance paths.
UPDATE api_keys
SET scopes_json = '["read","publish","device:register","actions:run"]'
WHERE label = 'Horizon OS'
  AND kind = 'app'
  AND purpose = 'device'
  AND revoked_at IS NULL
  AND scopes_json = '["read","device:register","actions:run"]';
