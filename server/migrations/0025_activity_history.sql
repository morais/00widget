-- Recently ended Live Activities.
--
-- An activity instance is deleted when it ends, which is right — the row exists
-- to address a running thing, and a producer addresses it by
-- `external_id` while it runs. But that left no way to answer "did my end
-- land?" or "what did this account run today?", so a producer that lost track
-- mid-run could only start a duplicate and hope.
--
-- Deliberately bounded rather than a log. Rows carry `expires_at` and are
-- reclaimed by the same sampled sweep that collects rate limit buckets; a
-- Live Activity's own ceiling is 8 hours plus a 4-hour dismissal window, so a
-- day of retention comfortably covers everything that could still be recent.
--
-- No index beyond the primary key. `(tenant_id, activity_instance_id)` makes a
-- per-tenant listing a range seek on the PK itself, and the sweep deletes by
-- rowid from a LIMITed subquery the way `rate_limit_buckets` does — so nothing
-- here adds a second write to a path that already writes.
CREATE TABLE IF NOT EXISTS activity_history (
  tenant_id TEXT NOT NULL,
  activity_instance_id TEXT NOT NULL,
  external_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  final_state TEXT,
  final_subtitle TEXT,
  started_at TEXT,
  ended_at TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, activity_instance_id)
);
