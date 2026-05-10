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
  actionRunTenantHour: { label: "Action runs", limit: 240, windowSeconds: HOUR },
  actionRunActionHour: { label: "Action runs per action", limit: 60, windowSeconds: HOUR },
  registrationTenantDay: { label: "Registrations", limit: 240, windowSeconds: DAY },
  webhookTenantDay: { label: "Webhook changes", limit: 20, windowSeconds: DAY },
  shareTenantDay: { label: "Share mutations", limit: 120, windowSeconds: DAY },
  appleLoginSubHour: { label: "Apple login token exchange", limit: 30, windowSeconds: HOUR },
  adminApiTokenLoginIpHour: { label: "Admin API-token login attempts", limit: 10, windowSeconds: HOUR },
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

export async function incrementRateLimitBuckets(
  env: Env,
  buckets: RateLimitBucketInput[],
): Promise<RateLimitExceeded | null> {
  const now = nowSeconds();
  let firstExceeded: RateLimitExceeded | null = null;
  await cleanupExpiredBuckets(env, now);

  for (const bucket of buckets) {
    const policy = RateLimitPolicies[bucket.policy];
    const windowStart = Math.floor(now / policy.windowSeconds) * policy.windowSeconds;
    const bucketKey = `${bucket.policy}:${bucket.key}`;
    const expiresAt = windowStart + policy.windowSeconds * 2;

    await env.ZW_DB.prepare(
      `INSERT INTO rate_limit_buckets (bucket_key, window_start, count, expires_at)
       VALUES (?, ?, 1, ?)
       ON CONFLICT(bucket_key, window_start) DO UPDATE SET
         count = count + 1,
         expires_at = excluded.expires_at`,
    )
      .bind(bucketKey, windowStart, expiresAt)
      .run();

    const row = await env.ZW_DB.prepare(
      `SELECT bucket_key, window_start, count, expires_at
       FROM rate_limit_buckets
       WHERE bucket_key = ? AND window_start = ?`,
    )
      .bind(bucketKey, windowStart)
      .first<BucketRow>();

    const count = Number(row?.count ?? 0);
    if (!firstExceeded && count > policy.limit) {
      const resetAt = windowStart + policy.windowSeconds;
      firstExceeded = {
        bucketKey,
        label: policy.label,
        limit: policy.limit,
        count,
        windowSeconds: policy.windowSeconds,
        retryAfter: Math.max(1, resetAt - now),
        resetAt,
      };
    }
  }
  return firstExceeded;
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
  await cleanupExpiredBuckets(env, now);
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

export function appleSubKey(sub: string): string {
  return `apple-sub:${sub}`;
}

function bucketRowToView(row: BucketRow, now: number): RateLimitBucketView | null {
  const policyName = row.bucket_key.split(":")[0] as RateLimitPolicyName;
  const policy = RateLimitPolicies[policyName];
  if (!policy) return null;
  const resetAt = Number(row.window_start) + policy.windowSeconds;
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

async function cleanupExpiredBuckets(env: Env, now: number): Promise<void> {
  try {
    await env.ZW_DB.prepare(`DELETE FROM rate_limit_buckets WHERE expires_at < ?`)
      .bind(now)
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
