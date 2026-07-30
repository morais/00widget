-- A suppressed WidgetKit reload is durable rather than dropped. One row per
-- receiving tenant coalesces any number of card changes until the cadence
-- window opens. `generation` prevents a delivery from deleting a newer update
-- that arrived while APNs was in flight.
CREATE TABLE widget_push_pending (
  tenant_id TEXT PRIMARY KEY,
  generation INTEGER NOT NULL DEFAULT 1,
  queued_at INTEGER NOT NULL
);

CREATE INDEX widget_push_pending_by_queued_at
  ON widget_push_pending(queued_at);
