-- Optional, bounded diagnostics for WidgetKit APNs deliveries.
--
-- The Worker writes this table only when WIDGET_PUSH_APNS_DIAGNOSTICS is
-- exactly "true". One row per push token is overwritten with the latest final
-- APNs result, so enabling diagnostics adds one D1 row write per attempted
-- widget reload without creating an unbounded event log.
CREATE TABLE widget_push_delivery_diagnostics (
  token TEXT PRIMARY KEY,
  attempted_at TEXT NOT NULL,
  status INTEGER NOT NULL,
  reason TEXT,
  apns_id TEXT,
  attempts INTEGER NOT NULL
);
