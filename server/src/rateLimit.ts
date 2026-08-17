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

export async function enforceTenantRateLimits(
  env: Env,
  auth: AuthContext,
  buckets: RateLimitBucketInput[],
): Promise<Response | null> {
  return enforceRateLimits(env, [
    { policy: "anyWriteTenantHour", key: tenantKey(auth.tenantId) },
    ...buckets,
  ]);
}

export async function enforceRateLimits(
  env: Env,
  buckets: RateLimitBucketInput[],
): Promise<Response | null> {
  const exceeded = await incrementRateLimitBuckets(env, buckets);
  if (!exceeded) return null;
  return rateLimitResponse(exceeded);
}

// One D1 round trip for the whole request, not two per bucket. `RETURNING`
// takes the new count off the write itself instead of re-reading the row, and
// `batch` sends every bucket together — this runs on the hot path of every
// authenticated write, and D1 latency, not CPU, is what the caller waits for.
// Expired rows are swept by the scheduled handler rather than here; sweeping
// per request cost a table-wide DELETE on every call and bought nothing that a
// once-a-minute cron does not.
export async function incrementRateLimitBuckets(
  env: Env,
  buckets: RateLimitBucketInput[],
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

  const results = await env.ZW_DB.batch<{ count: number }>(
    planned.map((entry) =>
      env.ZW_DB.prepare(
        `INSERT INTO rate_limit_buckets (bucket_key, window_start, count, expires_at)
         VALUES (?, ?, 1, ?)
         ON CONFLICT(bucket_key, window_start) DO UPDATE SET
           count = count + 1,
           expires_at = excluded.expires_at
         RETURNING count`,
      ).bind(entry.bucketKey, entry.windowStart, entry.expiresAt),
    ),
  );

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

// Called from the scheduled handler. The table carries no index on
// `expires_at` — one would double the cost of every counter increment, which is
// the hottest write in the system, to speed up a sweep that runs once a minute
// over a table holding only live windows.
export async function sweepExpiredRateLimitBuckets(env: Env): Promise<void> {
  try {
    await env.ZW_DB.prepare(`DELETE FROM rate_limit_buckets WHERE expires_at < ?`)
      .bind(nowSeconds())
      .run();
  } catch (err) {
    console.warn("rate_limit.cleanup_failed", {
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}
