-- Drops eight indexes that no query plan needs.
--
-- D1 bills index maintenance as rows written, and rows written cost 1000x rows
-- read, so an index on a column a write path touches is a multiplier on the
-- hottest thing the system does. 0023 removed `rate_limit_buckets_expires` on
-- that reasoning and measured the upsert fall from 2.04 rows to ~1. These are
-- the same move on the tables the publish path writes.
--
-- Each one was checked by running every statement in `src/` that touches its
-- table through EXPLAIN QUERY PLAN, against a seeded database, before and after
-- the drop. Only two plans changed at all, and both changed to an equivalent
-- seek on the implicit index SQLite already maintains for a UNIQUE constraint:
--
--   listTenantCards  cards_by_tenant_updated (tenant_id=?)
--                 -> sqlite_autoindex_cards_1 (tenant_id=?)
--   requireAuth      api_keys_by_token_hash (token_hash=?)
--                 -> sqlite_autoindex_api_keys_2 (token_hash=?)
--
-- Note the second: it is the authentication lookup on every single request, and
-- it is unaffected because `token_hash TEXT NOT NULL UNIQUE` had already built
-- an index over exactly that column. `api_keys_by_token_hash` was a duplicate
-- of it from the day it was written.
--
-- FakeD1 models no indexes, so the unit suite cannot tell you whether one of
-- these was load-bearing. If a later change adds a query that wants one back,
-- add it back deliberately — and price the write first.

-- cards: written on every publish, the hottest write a producer causes.
--   cards_by_tenant_updated  Nothing filters or orders by updated_at.
--                            `listCards` orders by id and `byPriorityThenId`
--                            re-sorts in memory; `listTenantCards` only orders
--                            by api_key_hash, which this index does not serve.
--   cards_by_api_key_hash    No reader at all. The credential-revocation
--                            cleanup in sessions.ts deletes from devices,
--                            widget_tokens, start_tokens and
--                            activity_deliveries, never from cards.
DROP INDEX IF EXISTS cards_by_tenant_updated;
DROP INDEX IF EXISTS cards_by_api_key_hash;

-- widget_push_pending: written on every publish whose reload is suppressed by
-- the cadence bucket, which in steady state is most of them. The only reader is
-- a primary-key lookup on tenant_id; nothing selects, filters or orders by
-- queued_at.
DROP INDEX IF EXISTS widget_push_pending_by_queued_at;

-- api_keys.
--   api_keys_by_token_hash  Duplicate of the UNIQUE constraint's own index.
--   api_keys_by_expiration  No query filters on expires_at alone. The guest
--                           sweep and listing both carry kind = 'guest' and hit
--                           the partial indexes from 0022.
--   api_keys_by_tenant      No query filters on tenant_id alone. The two that
--                           filter tenant_id also carry kind or session_id, and
--                           are served by api_keys_by_tenant_kind and
--                           api_keys_by_session. `listApiKeys` is an unfiltered
--                           ORDER BY created_at, which a (tenant_id, ...) index
--                           cannot help and which already scans.
DROP INDEX IF EXISTS api_keys_by_token_hash;
DROP INDEX IF EXISTS api_keys_by_expiration;
DROP INDEX IF EXISTS api_keys_by_tenant;

-- widget_tokens_by_tenant is a strict prefix of
-- PRIMARY KEY (tenant_id, device_id, widget_kind); every tenant-scoped read
-- already plans against the primary key's own index.
--
-- The other three stay. widget_tokens_by_tenant_kind, widget_tokens_by_tenant_token
-- and widget_tokens_by_api_key_hash are each the chosen plan for a live query.
DROP INDEX IF EXISTS widget_tokens_by_tenant;

-- activity_instances_by_api_key_hash has no reader; the instance is addressed
-- by id or by (owner_tenant_id, external_id), and the admin listing joins from
-- deliveries. The matching index on activity_deliveries stays — unlike this
-- one, it is the plan the revocation cleanup actually uses.
DROP INDEX IF EXISTS activity_instances_by_api_key_hash;
