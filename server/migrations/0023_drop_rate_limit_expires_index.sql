-- D1 bills index maintenance as rows written, so this index doubled the cost of
-- the hottest write in the system: every rate limit counter increment wrote the
-- base row plus an index entry (measured at 2.04 rows per upsert). Its only
-- reader was the expiry sweep, which now runs on a cron over a table that holds
-- just the live windows, where a scan is cheap.
DROP INDEX IF EXISTS rate_limit_buckets_expires;
