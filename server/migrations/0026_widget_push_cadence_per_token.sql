-- Reload cadence per widget, as a token bucket.
--
-- Two problems with what this replaces, a single `last_sent_at` per tenant.
--
-- Apple budgets WidgetKit reloads per *widget instance*: "WidgetKit maintains
-- different budgets for each active widget the user adds to their device."
-- Keying by tenant modelled one shared allowance, so publishing a solar card
-- blocked an unrelated washer widget from reloading.
--
-- And a flat interval is the wrong shape for a daily budget. It cannot burst
-- when something actually happens, and cannot save what it does not spend
-- while nothing does. A plain daily quota has the opposite failure: forty
-- pushes five minutes apart exhausts a day in three hours and twenty minutes,
-- leaving the widget dark for the next twenty.
--
-- A bucket has neither failure. `allowance` refills continuously, so a widget
-- always regains a push after a quiet stretch and can never starve; the cap on
-- the bucket bounds how much can be spent at once.
--
-- The old table is dropped rather than migrated. It held one integer per
-- tenant, and losing it costs at most one extra push per widget after deploy.
DROP TABLE IF EXISTS widget_push_cadence;

CREATE TABLE widget_push_cadence (
  token TEXT PRIMARY KEY,
  -- Enforces the minimum spacing, and is the point the refill accrues from.
  last_sent_at INTEGER NOT NULL,
  -- Pushes in hand, as a fraction. Refilled by elapsed time on every claim
  -- rather than by a sweep, so an idle widget costs nothing to keep current.
  allowance REAL NOT NULL
);
