ALTER TABLE widget_tokens
  ADD COLUMN app_version TEXT NOT NULL DEFAULT '';

ALTER TABLE widget_tokens
  ADD COLUMN platform TEXT NOT NULL DEFAULT 'ios';

-- One compact row per tenant bounds reload pushes without recording individual
-- deliveries. A conditional UPSERT means suppressed pushes cause no writes.
CREATE TABLE widget_push_cadence (
  tenant_id TEXT PRIMARY KEY,
  last_sent_at INTEGER NOT NULL
);
