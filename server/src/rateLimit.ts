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

/// Sentinel for the aggregate, whose source is "every hourly write bucket this
/// tenant holds" rather than one named policy.
const AGGREGATE = "*" as const;

/// Totals that are not stored, because they are already implied by the buckets
/// underneath them. A tenant's card upserts in an hour *are* the sum of its
/// per-card buckets in that hour; storing the sum too meant a second row write
/// on every publish to record a fact the first row already contained.
///
/// Deriving costs a range read instead. Rows read are a thousandth the price of
/// rows written, and the read is bounded by the very limits it enforces: a
/// tenant cannot hold more per-card buckets in a window than the tenant-wide
/// limit will admit publishes.
const DERIVED_TOTALS: Partial<Record<RateLimitPolicyName, RateLimitPolicyName | typeof AGGREGATE>> = {
  cardUpsertTenantHour: "cardUpsertCardHour",
  liveActivityUpdateTenantHour: "liveActivityUpdateActivityHour",
  actionRunTenantHour: "actionRunActionHour",
  liveActivityRecoveryTenantHour: "liveActivityRecoveryDeviceActivityHour",
  anyWriteTenantHour: AGGREGATE,
};

/// What the aggregate counts, named rather than inferred.
///
/// Every one is hourly and is a bucket that is actually written, so summing
/// them double-counts nothing. The day-windowed policies — registrations,
/// webhook changes, share mutations — are deliberately absent: they sit in a
/// different window, so they could only be folded in by comparing against a
/// boundary that happens to coincide at midnight and not otherwise. They keep
/// their own daily caps, and the aggregate is what it says, an hourly ceiling
/// on publishing volume.
const AGGREGATE_WRITE_POLICIES = new Set<RateLimitPolicyName>([
  "cardUpsertCardHour",
  "liveActivityStartTenantHour",
  "liveActivityUpdateActivityHour",
  "liveActivityEndTenantHour",
  "liveActivityRecoveryDeviceActivityHour",
  "actionRunActionHour",
]);

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
/// Sums the stored buckets that make up a derived total, for one window.
function deriveTotal(
  rows: Array<{ bucket_key: string; window_start: number | string; count: number | string }>,
  source: RateLimitPolicyName | typeof AGGREGATE,
  windowStart: number,
): number {
  let total = 0;
  for (const row of rows) {
    if (Number(row.window_start) !== windowStart) continue;
    const rowPolicy = policyOf(row.bucket_key);
    if (!rowPolicy) continue;
    const contributes = source === AGGREGATE
      ? AGGREGATE_WRITE_POLICIES.has(rowPolicy)
      : rowPolicy === source;
    if (contributes) total += Number(row.count);
  }
  return total;
}

export async function incrementRateLimitBuckets(
  env: Env,
  buckets: RateLimitBucketInput[],
  owner?: object,
): Promise<RateLimitExceeded | null> {
  if (buckets.length === 0) return null;
  const now = nowSeconds();

  // Coalesced by bucket key, because a caller may name the same bucket many
  // times in one request and every repeat would otherwise be its own write to
  // the same row. A ten-card batch upsert charges `cardUpsertTenantHour` once
  // per card, which was ten identical upserts plus ten identical deletes; the
  // policy name is part of the key, so grouping can never merge two policies.
  //
  // `weight` keeps the accounting identical — ten repeats still spend ten — so
  // this is purely the same arithmetic done in one statement instead of ten.
  // Insertion order is preserved so the first bucket to exceed is still
  // reported first.
  const planned = [...buckets
    .reduce((grouped, bucket) => {
      const policy = RateLimitPolicies[bucket.policy];
      const bucketKey = bucketKeyFor(bucket.policy, bucket.key);
      const existing = grouped.get(bucketKey);
      if (existing) {
        existing.weight += 1;
        return grouped;
      }
      const windowStart = Math.floor(now / policy.windowSeconds) * policy.windowSeconds;
      grouped.set(bucketKey, {
        policy,
        policyName: bucket.policy,
        scope: bucket.key,
        windowStart,
        bucketKey,
        expiresAt: windowStart + policy.windowSeconds * 2,
        weight: 1,
      });
      return grouped;
    }, new Map<string, {
      policy: typeof RateLimitPolicies[RateLimitPolicyName];
      policyName: RateLimitPolicyName;
      scope: string;
      windowStart: number;
      bucketKey: string;
      expiresAt: number;
      weight: number;
    }>())
    .values()];

  // Only the buckets that are actually stored get written. A tenant-wide total
  // is the sum of the per-resource buckets underneath it, so counting it
  // separately stored the same fact twice and paid a row write for the copy —
  // and rows written cost 1000x rows read. `cardUpsertTenantHour` is exactly
  // the sum of that tenant's `cardUpsertCardHour` buckets in the window, and
  // the aggregate is the sum of every hourly write bucket it holds.
  //
  // So a card upsert writes one row where it used to write three, and reads a
  // handful to check the two limits it no longer counts.
  const written = planned.filter((entry) => !DERIVED_TOTALS[entry.policyName]);
  const derived = planned.filter((entry) => DERIVED_TOTALS[entry.policyName]);
  // Every derivable policy is tenant-scoped, and one request only ever touches
  // one tenant, so a single range covers all of them.
  const derivedScope = derived[0]?.scope;

  const statements = [
    ...written.map((entry) =>
      env.ZW_DB.prepare(
        `INSERT INTO rate_limit_buckets (bucket_key, window_start, count, expires_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(bucket_key, window_start) DO UPDATE SET
           count = count + ?,
           expires_at = excluded.expires_at
         RETURNING count`,
      ).bind(entry.bucketKey, entry.windowStart, entry.weight, entry.expiresAt, entry.weight),
    ),
    ...written.map((entry) =>
      env.ZW_DB.prepare(
        `DELETE FROM rate_limit_buckets WHERE bucket_key = ? AND window_start < ?`,
      ).bind(entry.bucketKey, entry.windowStart),
    ),
  ];
  // Last, so it observes this request's own increments: a D1 batch runs in
  // order inside one transaction, which is what keeps the derived totals from
  // lagging the write that just happened.
  if (derivedScope !== undefined) {
    const [low, high] = scopeRange(derivedScope);
    statements.push(
      env.ZW_DB.prepare(
        `SELECT bucket_key, window_start, count
         FROM rate_limit_buckets
         WHERE bucket_key >= ? AND bucket_key < ?`,
      ).bind(low, high),
    );
  }

  const results = await env.ZW_DB.batch<{ count: number }>(statements);

  const counts = new Map<string, number>();
  for (const [index, entry] of written.entries()) {
    counts.set(entry.bucketKey, Number(results[index]?.results?.[0]?.count ?? 0));
  }
  if (derivedScope !== undefined) {
    const rows = (results[results.length - 1]?.results ?? []) as unknown as Array<{
      bucket_key: string; window_start: number; count: number;
    }>;
    for (const entry of derived) {
      const source = DERIVED_TOTALS[entry.policyName]!;
      counts.set(entry.bucketKey, deriveTotal(rows, source, entry.windowStart));
    }
  }

  // The tightest bucket, whether or not anything was exceeded: it is the one
  // that will bite first, so it is the one worth reporting back.
  let tightest: RateLimitSnapshot | undefined;
  for (const entry of planned) {
    const count = counts.get(entry.bucketKey) ?? 0;
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

  for (const entry of planned) {
    const count = counts.get(entry.bucketKey) ?? 0;
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
  const [low, high] = scopeRange(tenantKey(tenantId));
  const rows = await env.ZW_DB.prepare(
    `SELECT bucket_key, window_start, count, expires_at
     FROM rate_limit_buckets
     WHERE bucket_key >= ? AND bucket_key < ?
     ORDER BY bucket_key, window_start DESC`,
  )
    .bind(low, high)
    .all<BucketRow>();

  const stored = rows.results
    .map((row) => bucketRowToView(row, now))
    .filter((row): row is RateLimitBucketView => Boolean(row));

  // The tenant-wide totals are no longer stored, so they have to be summed back
  // out of the buckets beneath them or `/v1/status` would silently stop
  // reporting the two limits a producer is most likely to pace itself against.
  const derived: RateLimitBucketView[] = [];
  for (const [name, source] of Object.entries(DERIVED_TOTALS)) {
    const policy = RateLimitPolicies[name as RateLimitPolicyName];
    const windowStart = Math.floor(now / policy.windowSeconds) * policy.windowSeconds;
    const count = deriveTotal(rows.results, source!, windowStart);
    // Same rule the stored rows follow: a window this account has not touched
    // has its full allowance and nothing to report.
    if (count === 0) continue;
    const resetAt = windowStart + policy.windowSeconds;
    derived.push({
      bucketKey: bucketKeyFor(name, tenantKey(tenantId)),
      label: policy.label,
      count,
      limit: policy.limit,
      remaining: Math.max(0, policy.limit - count),
      windowSeconds: policy.windowSeconds,
      resetAt,
      retryAfter: Math.max(0, resetAt - now),
    });
  }
  return [...stored, ...derived];
}

// A bucket key is `<scope>|<policy>`, scope first.
//
// The policy used to lead, which meant one tenant's counters were scattered
// across the key space and the only way to find them was a leading-wildcard
// `LIKE`, which SQLite cannot answer from an index. `GET /v1/status` therefore
// scanned the whole table — the hottest table in the system — on a route
// producers are told to poll. Scope first makes a tenant's buckets one
// contiguous range, which the primary key answers with a seek.
//
// `|` (0x7C) as the separator because it cannot occur in any scope: tenant and
// guest scopes carry UUIDs, and the IP and Apple-subject scopes are their own
// prefixes. No tenant id is a prefix of another either — they are fixed-length
// UUIDs — so a range over one tenant cannot spill into the next.
const SCOPE_SEPARATOR = "|";

export function bucketKeyFor(policy: string, scope: string): string {
  return `${scope}${SCOPE_SEPARATOR}${policy}`;
}

/// Half-open `[low, high)` bounds covering every bucket under one scope.
///
/// `}` is 0x7D, one past the separator, and above the `:` (0x3A) that appears
/// inside a resource-qualified scope — so the range covers `tenant:<id>|policy`
/// and `tenant:<id>:card:solar|policy` alike, and stops before any other scope.
export function scopeRange(scope: string): [string, string] {
  return [scope, `${scope}}`];
}

function policyOf(bucketKey: string): RateLimitPolicyName | undefined {
  const separator = bucketKey.lastIndexOf(SCOPE_SEPARATOR);
  if (separator < 0) return undefined;
  const name = bucketKey.slice(separator + 1) as RateLimitPolicyName;
  return name in RateLimitPolicies ? name : undefined;
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
  const policyName = policyOf(row.bucket_key);
  const policy = policyName ? RateLimitPolicies[policyName] : undefined;
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
