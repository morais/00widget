import type { AuthContext } from "./auth";
import { json } from "./http";
import type { Env } from "./types";

const HOUR = 60 * 60;
const DAY = 24 * HOUR;

export const RateLimitPolicies = {
  anyWriteTenantHour: { label: "All writes", limit: 1000, windowSeconds: HOUR },
  cardUpsertTenantHour: { label: "Card upserts", limit: 600, windowSeconds: HOUR },
  cardUpsertCardHour: { label: "Card upserts per card", limit: 60, windowSeconds: HOUR },
  liveActivityStartTenantHour: { label: "Live Activity starts", limit: 120, windowSeconds: HOUR },
  liveActivityUpdateTenantHour: { label: "Live Activity updates", limit: 600, windowSeconds: HOUR },
  liveActivityUpdateActivityHour: { label: "Live Activity updates per activity", limit: 120, windowSeconds: HOUR },
  liveActivityEndTenantHour: { label: "Live Activity ends", limit: 240, windowSeconds: HOUR },
  liveActivityRecoveryTenantHour: { label: "Live Activity recoveries", limit: 60, windowSeconds: HOUR },
  liveActivityRecoveryDeviceActivityHour: { label: "Live Activity recoveries per device and activity", limit: 6, windowSeconds: HOUR },
  actionRunTenantHour: { label: "Action runs", limit: 240, windowSeconds: HOUR },
  actionRunActionHour: { label: "Action runs per action", limit: 60, windowSeconds: HOUR },
  registrationTenantDay: { label: "Registrations", limit: 240, windowSeconds: DAY },
  webhookTenantDay: { label: "Webhook changes", limit: 20, windowSeconds: DAY },
  shareTenantDay: { label: "Share mutations", limit: 120, windowSeconds: DAY },
  // Keyed on the guest credential, never the owner's tenant. A QR code is a
  // bearer token with no per-person identity, so charging a guest's
  // registration to the owner would let one widely-shown code exhaust the
  // owner's budget and lock them out of registering their own devices.
  guestRegistrationDay: { label: "Guest registrations", limit: 60, windowSeconds: DAY },
  appleLoginIpHour: { label: "Apple login attempts per IP", limit: 60, windowSeconds: HOUR },
  appleLoginSubHour: { label: "Apple login token exchange", limit: 30, windowSeconds: HOUR },
  adminApiTokenLoginIpHour: { label: "Admin API-token login attempts", limit: 10, windowSeconds: HOUR },
  adminAppleCallbackIpHour: { label: "Admin Apple callback attempts", limit: 60, windowSeconds: HOUR },
  // OAuth for the MCP endpoint. Both are keyed on the caller IP because
  // neither request carries a tenant yet: registration invents a client and
  // the token exchange is what mints the credential.
  mcpClientRegisterIpDay: { label: "MCP client registrations", limit: 20, windowSeconds: DAY },
  mcpTokenIpHour: { label: "MCP token exchanges", limit: 30, windowSeconds: HOUR },
  // Receipt verification. Generous because the app re-verifies on every launch
  // and on every StoreKit update, and a subscriber locked out of proving they
  // have paid is the worst failure this whole feature has.
  subscriptionVerifyTenantHour: { label: "Subscription verifications", limit: 120, windowSeconds: HOUR },
  // Keyed on caller IP: an App Store Server Notification carries no tenant, and
  // verifying its certificate chain is real CPU. Apple's own volume for one app
  // is orders of magnitude below this.
  appleNotificationIpHour: { label: "App Store notifications", limit: 600, windowSeconds: HOUR },
} as const;

type RateLimitPolicyName = keyof typeof RateLimitPolicies;

export interface RateLimitBucketInput {
  policy: RateLimitPolicyName;
  key: string;
}

export interface RateLimitExceeded {
  bucketKey: string;
  label: string;
  limit: number;
  count: number;
  windowSeconds: number;
  retryAfter: number;
  resetAt: number;
}

export interface RateLimitBucketView {
  bucketKey: string;
  label: string;
  count: number;
  limit: number;
  remaining: number;
  windowSeconds: number;
  resetAt: number;
  retryAfter: number;
}

interface BucketRow {
  bucket_key: string;
  window_start: number;
  count: number;
  expires_at: number;
}

/// What a caller has left on the tightest limit this request touched.
export interface RateLimitSnapshot {
  label: string;
  limit: number;
  remaining: number;
  resetAt: number;
}

/// Recorded per request so the response can carry it, keyed on the
/// `AuthContext` — which `requireAuth` mints fresh for every request and drops
/// afterwards, and which is the one request-scoped object every rate-limited
/// handler already holds. Threading a return value through all twenty-six call
/// sites would say the same thing twenty-six times to reach one place that
/// uses it.
const snapshots = new WeakMap<object, RateLimitSnapshot>();

export function rateLimitSnapshotFor(owner: object): RateLimitSnapshot | undefined {
  return snapshots.get(owner);
}

export async function enforceTenantRateLimits(
  env: Env,
  auth: AuthContext,
  buckets: RateLimitBucketInput[],
): Promise<Response | null> {
  return enforceRateLimits(env, [
    { policy: "anyWriteTenantHour", key: tenantKey(auth.tenantId) },
    ...buckets,
  ], auth);
}

export async function enforceRateLimits(
  env: Env,
  buckets: RateLimitBucketInput[],
  owner?: object,
): Promise<Response | null> {
  const exceeded = await incrementRateLimitBuckets(env, buckets, owner);
  if (!exceeded) return null;
  return rateLimitResponse(exceeded);
}

// One D1 round trip for the whole request, not two per bucket. `RETURNING`
// takes the new count off the write itself instead of re-reading the row, and
// `batch` sends every bucket together — this runs on the hot path of every
// authenticated write, and D1 latency, not CPU, is what the caller waits for.
// Garbage collection rides along in the same batch. The old code swept the
// whole table on every call; this deletes only the closed windows of the keys
// this request already touches, which the primary key answers with a seek
// (`SEARCH ... USING INDEX sqlite_autoindex_rate_limit_buckets_1`) and which
// writes nothing at all unless a window has actually rolled over. A key that
// goes permanently silent keeps its last row or two until the sampled sweep on
// the queue consumer reclaims it — see `sweepExpiredRateLimitBuckets`.
export async function incrementRateLimitBuckets(
  env: Env,
  buckets: RateLimitBucketInput[],
  owner?: object,
): Promise<RateLimitExceeded | null> {
  if (buckets.length === 0) return null;
  const now = nowSeconds();

  const planned = buckets.map((bucket) => {
    const policy = RateLimitPolicies[bucket.policy];
    const windowStart = Math.floor(now / policy.windowSeconds) * policy.windowSeconds;
    return {
      policy,
      windowStart,
      bucketKey: `${bucket.policy}:${bucket.key}`,
      expiresAt: windowStart + policy.windowSeconds * 2,
    };
  });

  // Upserts first so a result index lines up with `planned`; the trailing
  // deletes are fire-and-forget.
  const results = await env.ZW_DB.batch<{ count: number }>([
    ...planned.map((entry) =>
      env.ZW_DB.prepare(
        `INSERT INTO rate_limit_buckets (bucket_key, window_start, count, expires_at)
         VALUES (?, ?, 1, ?)
         ON CONFLICT(bucket_key, window_start) DO UPDATE SET
           count = count + 1,
           expires_at = excluded.expires_at
         RETURNING count`,
      ).bind(entry.bucketKey, entry.windowStart, entry.expiresAt),
    ),
    ...planned.map((entry) =>
      env.ZW_DB.prepare(
        `DELETE FROM rate_limit_buckets WHERE bucket_key = ? AND window_start < ?`,
      ).bind(entry.bucketKey, entry.windowStart),
    ),
  ]);

  // The tightest bucket, whether or not anything was exceeded: it is the one
  // that will bite first, so it is the one worth reporting back.
  let tightest: RateLimitSnapshot | undefined;
  for (const [index, entry] of planned.entries()) {
    const count = Number(results[index]?.results?.[0]?.count ?? 0);
    const remaining = Math.max(0, entry.policy.limit - count);
    if (!tightest || remaining < tightest.remaining) {
      tightest = {
        label: entry.policy.label,
        limit: entry.policy.limit,
        remaining,
        resetAt: entry.windowStart + entry.policy.windowSeconds,
      };
    }
  }
  if (owner && tightest) snapshots.set(owner, tightest);

  for (const [index, entry] of planned.entries()) {
    const count = Number(results[index]?.results?.[0]?.count ?? 0);
    if (count <= entry.policy.limit) continue;
    const resetAt = entry.windowStart + entry.policy.windowSeconds;
    return {
      bucketKey: entry.bucketKey,
      label: entry.policy.label,
      limit: entry.policy.limit,
      count,
      windowSeconds: entry.policy.windowSeconds,
      retryAfter: Math.max(1, resetAt - now),
      resetAt,
    };
  }
  return null;
}

export function rateLimitResponse(exceeded: RateLimitExceeded): Response {
  return json(
    {
      error: "rate limit exceeded",
      bucket: exceeded.label,
      limit: exceeded.limit,
      windowSeconds: exceeded.windowSeconds,
      retryAfter: exceeded.retryAfter,
      resetAt: new Date(exceeded.resetAt * 1000).toISOString(),
    },
    429,
    {
      "Retry-After": String(exceeded.retryAfter),
      "X-RateLimit-Limit": String(exceeded.limit),
      "X-RateLimit-Remaining": "0",
      "X-RateLimit-Reset": String(exceeded.resetAt),
    },
  );
}

export async function listTenantRateLimitBuckets(
  env: Env,
  tenantId: string,
): Promise<RateLimitBucketView[]> {
  const now = nowSeconds();
  const prefix = `%:tenant:${tenantId}%`;
  const rows = await env.ZW_DB.prepare(
    `SELECT bucket_key, window_start, count, expires_at
     FROM rate_limit_buckets
     WHERE bucket_key LIKE ?
     ORDER BY bucket_key, window_start DESC`,
  )
    .bind(prefix)
    .all<BucketRow>();

  return rows.results
    .map((row) => bucketRowToView(row, now))
    .filter((row): row is RateLimitBucketView => Boolean(row));
}

export function tenantKey(tenantId: string): string {
  return `tenant:${tenantId}`;
}

export function tenantResourceKey(tenantId: string, kind: string, id: string): string {
  return `tenant:${tenantId}:${kind}:${id}`;
}

export function guestCredentialKey(apiKeyId: string): string {
  return `guest-credential:${apiKeyId}`;
}

export function appleSubKey(sub: string): string {
  return `apple-sub:${sub}`;
}

function bucketRowToView(row: BucketRow, now: number): RateLimitBucketView | null {
  const policyName = row.bucket_key.split(":")[0] as RateLimitPolicyName;
  const policy = RateLimitPolicies[policyName];
  if (!policy) return null;
  const resetAt = Number(row.window_start) + policy.windowSeconds;
  // Rows outlive their window by design — `expires_at` is two windows out, so
  // the sweep never races a counter that is still being incremented. A closed
  // window is not current usage, so it does not belong in this view.
  if (resetAt <= now) return null;
  const count = Number(row.count);
  return {
    bucketKey: row.bucket_key,
    label: policy.label,
    count,
    limit: policy.limit,
    remaining: Math.max(0, policy.limit - count),
    windowSeconds: policy.windowSeconds,
    resetAt,
    retryAfter: Math.max(0, resetAt - now),
  };
}

// Reclaims buckets no request will touch again — the counter of a Live Activity
// that has ended, of a card that was deleted. Live keys collect themselves in
// `incrementRateLimitBuckets`; these are the orphans, and their key space grows
// with events rather than with tenants.
//
// Called from the queue consumer (sampled, under `waitUntil`) and from the
// `scheduled` handler if a cron trigger is ever wired up.
//
// The work is bounded on purpose. There is no index on `expires_at` — one would
// double the cost of every counter increment, the hottest write in the system —
// so an unqualified `DELETE ... WHERE expires_at < ?` scans the table, and it
// would do so most expensively in exactly the situation that makes the sweep
// worth running. Deleting by `rowid` from a `LIMIT`ed subquery costs a rowid
// seek per row and a scan that stops at the first full chunk, so one call is
// bounded no matter how far behind the table has fallen. Chunks repeat up to a
// ceiling and stop early on a short one, which is what lets a single call still
// make real progress against a backlog.
const SWEEP_CHUNK_SIZE = 500;
const SWEEP_MAX_CHUNKS = 10;

export async function sweepExpiredRateLimitBuckets(env: Env): Promise<number> {
  let deleted = 0;
  try {
    for (let chunk = 0; chunk < SWEEP_MAX_CHUNKS; chunk += 1) {
      const result = await env.ZW_DB.prepare(
        `DELETE FROM rate_limit_buckets WHERE rowid IN (
           SELECT rowid FROM rate_limit_buckets WHERE expires_at < ? LIMIT ?
         ) RETURNING rowid`,
      )
        .bind(nowSeconds(), SWEEP_CHUNK_SIZE)
        .all<{ rowid: number }>();
      // Counted from RETURNING rather than `meta.changes`: the rows deleted are
      // the loop's exit condition, and this way the count comes from the same
      // statement that did the work instead of a metadata field whose presence
      // is not part of any contract we can check.
      const removed = result.results.length;
      deleted += removed;
      if (removed < SWEEP_CHUNK_SIZE) break;
    }
  } catch (err) {
    console.warn("rate_limit.cleanup_failed", {
      error: err instanceof Error ? err.message : String(err),
    });
  }
  return deleted;
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}
