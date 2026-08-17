import { describe, it, expect, vi, afterEach } from "vitest";
import handler from "../src/index";
import {
  RateLimitPolicies,
  incrementRateLimitBuckets,
  listTenantRateLimitBuckets,
  sweepExpiredRateLimitBuckets,
  tenantKey,
} from "../src/rateLimit";
import { makeEnv } from "./helpers";

const scheduledEvent = {
  cron: "0 * * * *",
  scheduledTime: Date.now(),
  noRetry() {},
} as unknown as ScheduledController;
const executionCtx = {} as ExecutionContext;

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("incrementRateLimitBuckets", () => {
  it("counts up to the limit and then reports the overage", async () => {
    const env = makeEnv();
    const policy = RateLimitPolicies.adminApiTokenLoginIpHour;
    const bucket = { policy: "adminApiTokenLoginIpHour", key: "ip:203.0.113.1" } as const;

    for (let attempt = 0; attempt < policy.limit; attempt += 1) {
      expect(await incrementRateLimitBuckets(env, [bucket])).toBeNull();
    }

    const exceeded = await incrementRateLimitBuckets(env, [bucket]);
    expect(exceeded).toMatchObject({
      label: policy.label,
      limit: policy.limit,
      count: policy.limit + 1,
      windowSeconds: policy.windowSeconds,
    });
    expect(exceeded!.retryAfter).toBeGreaterThan(0);
  });

  // The counter increment is on the hot path of every authenticated write. It
  // used to cost two round trips per bucket — an upsert then a re-read — plus a
  // table-wide DELETE before any of them. Anything above one batch here is a
  // latency and D1-cost regression, so the count is asserted, not just the
  // behaviour.
  it("spends exactly one D1 round trip however many buckets it checks", async () => {
    const env = makeEnv();
    const batch = vi.spyOn(env.ZW_DB, "batch");
    const prepare = vi.spyOn(env.ZW_DB, "prepare");

    await incrementRateLimitBuckets(env, [
      { policy: "anyWriteTenantHour", key: tenantKey("t1") },
      { policy: "cardUpsertTenantHour", key: tenantKey("t1") },
      { policy: "cardUpsertCardHour", key: "tenant:t1:card:solar" },
    ]);

    // Three counters and their three garbage-collecting deletes, in one trip.
    expect(batch).toHaveBeenCalledTimes(1);
    expect(batch.mock.calls[0][0]).toHaveLength(6);
    expect(prepare).toHaveBeenCalledTimes(6);
    expect(prepare.mock.calls.filter(([sql]) => sql.includes("RETURNING count"))).toHaveLength(3);
    expect(prepare.mock.calls.filter(([sql]) => sql.includes("window_start < ?"))).toHaveLength(3);
  });

  it("drops a key's closed windows as it counts the current one", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-17T10:00:00Z"));
    const env = makeEnv();
    const bucket = { policy: "cardUpsertTenantHour", key: tenantKey("t1") } as const;
    await incrementRateLimitBuckets(env, [bucket]);

    // Two windows on, the 10:00 row is still inside its two-window expiry and
    // would survive the sweep — the in-batch delete is what removes it.
    vi.setSystemTime(new Date("2026-08-17T12:10:00Z"));
    await incrementRateLimitBuckets(env, [bucket]);

    const views = await listTenantRateLimitBuckets(env, "t1");
    expect(views).toHaveLength(1);
    expect(views[0].count).toBe(1);
  });

  it("reports the first exceeded bucket while still counting the rest", async () => {
    const env = makeEnv();
    const tight = { policy: "webhookTenantDay", key: tenantKey("t1") } as const;
    const loose = { policy: "anyWriteTenantHour", key: tenantKey("t1") } as const;

    for (let attempt = 0; attempt < RateLimitPolicies.webhookTenantDay.limit; attempt += 1) {
      await incrementRateLimitBuckets(env, [loose, tight]);
    }
    const exceeded = await incrementRateLimitBuckets(env, [loose, tight]);
    expect(exceeded?.label).toBe(RateLimitPolicies.webhookTenantDay.label);

    const views = await listTenantRateLimitBuckets(env, "t1");
    const looseView = views.find((view) => view.label === RateLimitPolicies.anyWriteTenantHour.label);
    expect(looseView?.count).toBe(RateLimitPolicies.webhookTenantDay.limit + 1);
  });

  it("does not touch D1 when there is nothing to count", async () => {
    const env = makeEnv();
    const batch = vi.spyOn(env.ZW_DB, "batch");
    expect(await incrementRateLimitBuckets(env, [])).toBeNull();
    expect(batch).not.toHaveBeenCalled();
  });
});

describe("listTenantRateLimitBuckets", () => {
  it("hides a window that has already closed", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-17T10:00:00Z"));
    const env = makeEnv();
    await incrementRateLimitBuckets(env, [
      { policy: "cardUpsertTenantHour", key: tenantKey("t1") },
    ]);
    expect(await listTenantRateLimitBuckets(env, "t1")).toHaveLength(1);

    // Still in D1 — rows outlive their window so the sweep cannot race a live
    // counter — but no longer current usage.
    vi.setSystemTime(new Date("2026-08-17T11:30:00Z"));
    expect(await listTenantRateLimitBuckets(env, "t1")).toHaveLength(0);
  });

  it("does not sweep on read", async () => {
    const env = makeEnv();
    await incrementRateLimitBuckets(env, [
      { policy: "cardUpsertTenantHour", key: tenantKey("t1") },
    ]);
    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    await listTenantRateLimitBuckets(env, "t1");
    expect(prepare).toHaveBeenCalledTimes(1);
    expect(prepare.mock.calls[0][0]).toContain("SELECT");
  });
});

describe("the scheduled sweep", () => {
  it("deletes buckets past their expiry and leaves live ones alone", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-17T10:00:00Z"));
    const env = makeEnv();
    await incrementRateLimitBuckets(env, [
      { policy: "cardUpsertTenantHour", key: tenantKey("t1") },
    ]);

    // expires_at is two windows out, so an hour later the row must survive.
    vi.setSystemTime(new Date("2026-08-17T11:30:00Z"));
    await sweepExpiredRateLimitBuckets(env);
    await incrementRateLimitBuckets(env, [
      { policy: "cardUpsertTenantHour", key: tenantKey("t1") },
    ]);
    expect(await listTenantRateLimitBuckets(env, "t1")).toHaveLength(1);

    vi.setSystemTime(new Date("2026-08-17T14:00:00Z"));
    await sweepExpiredRateLimitBuckets(env);
    vi.setSystemTime(new Date("2026-08-17T11:30:00Z"));
    expect(await listTenantRateLimitBuckets(env, "t1")).toHaveLength(0);
  });

  it("is what the cron trigger runs", async () => {
    const env = makeEnv();
    await incrementRateLimitBuckets(env, [
      { policy: "cardUpsertTenantHour", key: tenantKey("t1") },
    ]);
    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    await handler.scheduled!(scheduledEvent, env, executionCtx);
    expect(prepare).toHaveBeenCalledTimes(1);
    expect(prepare.mock.calls[0][0]).toContain("DELETE FROM rate_limit_buckets");
  });

  it("survives a failing sweep rather than failing the cron run", async () => {
    const env = makeEnv();
    vi.spyOn(env.ZW_DB, "prepare").mockImplementation(() => {
      throw new Error("D1 unavailable");
    });
    await expect(handler.scheduled!(scheduledEvent, env, executionCtx)).resolves.toBeUndefined();
  });
});
