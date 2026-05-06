CREATE TABLE IF NOT EXISTS rate_limit_buckets (
  bucket_key TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (bucket_key, window_start)
);

CREATE INDEX IF NOT EXISTS rate_limit_buckets_expires
  ON rate_limit_buckets(expires_at);
