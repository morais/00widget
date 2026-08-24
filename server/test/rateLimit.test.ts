import { describe, it, expect, vi, afterEach } from "vitest";
import handler from "../src/index";
import {
  RateLimitPolicies,
  incrementRateLimitBuckets,
  listTenantRateLimitBuckets,
  sweepExpiredRateLimitBuckets,
  tenantKey,
  tenantResourceKey,
} from "../src/rateLimit";
import { authedRequest, makeEnv } from "./helpers";

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

  // A batch upsert charges `cardUpsertTenantHour` once per card, all under the
  // same key. Ten cards used to mean ten identical upserts and ten identical
  // deletes against one row — ten rows written where one does, on the write
  // path D1 charges most for.
  it("writes one statement per distinct bucket, however often a caller names it", async () => {
    const env = makeEnv();
    const prepare = vi.spyOn(env.ZW_DB, "prepare");

    await incrementRateLimitBuckets(env, [
      { policy: "anyWriteTenantHour", key: tenantKey("t1") },
      // Ten cards' worth of the same tenant-wide counter, plus two distinct
      // per-card counters.
      ...Array.from({ length: 10 }, () => ({
        policy: "cardUpsertTenantHour" as const,
        key: tenantKey("t1"),
      })),
      { policy: "cardUpsertCardHour", key: "tenant:t1:card:a" },
      { policy: "cardUpsertCardHour", key: "tenant:t1:card:b" },
    ]);

    // Four distinct buckets from thirteen inputs, so four upserts and four
    // deletes rather than thirteen of each.
    const upserts = prepare.mock.calls.filter(([sql]) => sql.includes("RETURNING count"));
    expect(upserts).toHaveLength(4);
    expect(prepare.mock.calls.filter(([sql]) => sql.includes("window_start < ?"))).toHaveLength(4);
  });

  it("still spends the full weight of a repeated bucket", async () => {
    // The saving must be in the number of writes, never in the accounting: ten
    // cards consume ten of the tenant's hourly card budget either way.
    const env = makeEnv();
    await incrementRateLimitBuckets(env, [
      ...Array.from({ length: 10 }, () => ({
        policy: "cardUpsertTenantHour" as const,
        key: tenantKey("t1"),
      })),
    ]);

    const view = (await listTenantRateLimitBuckets(env, "t1"))
      .find((entry) => entry.label === RateLimitPolicies.cardUpsertTenantHour.label);
    expect(view?.count).toBe(10);
    expect(view?.remaining).toBe(RateLimitPolicies.cardUpsertTenantHour.limit - 10);
  });

  it("reports a repeated bucket that the batch itself pushes over the limit", async () => {
    // One request can now cross the line on its own rather than one count at a
    // time, so the overage has to be detected from the post-increment count
    // rather than assumed to be exactly limit + 1.
    const env = makeEnv();
    const policy = RateLimitPolicies.cardUpsertCardHour;
    const bucket = { policy: "cardUpsertCardHour", key: "tenant:t1:card:a" } as const;

    const exceeded = await incrementRateLimitBuckets(
      env,
      Array.from({ length: policy.limit + 5 }, () => bucket),
    );
    expect(exceeded).toMatchObject({ label: policy.label, count: policy.limit + 5 });
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

  // The status route reads one tenant's buckets. With the policy leading the
  // key those were scattered, and the only way to find them was a
  // leading-wildcard LIKE, which SQLite answers by scanning — the whole of the
  // hottest table in the system, on a route producers are told to poll.
  // Confirmed against production: `LIKE 'prefix%'` plans as SCAN, a `>= ? AND
  // < ?` range as SEARCH on the primary key.
  it("reads a tenant's buckets by range rather than by scanning for them", async () => {
    const env = makeEnv();
    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    await listTenantRateLimitBuckets(env, "t1");

    const [sql] = prepare.mock.calls.at(-1)!;
    expect(sql).toContain("bucket_key >= ?");
    expect(sql).toContain("bucket_key < ?");
    expect(sql).not.toContain("LIKE");
  });

  it("covers a tenant's resource-scoped buckets in that range, and no one else's", async () => {
    // The range has to span both key shapes — `tenant:<id>|policy` and
    // `tenant:<id>:card:solar|policy` — while stopping before the next scope.
    const env = makeEnv();
    await incrementRateLimitBuckets(env, [
      { policy: "cardUpsertTenantHour", key: tenantKey("t1") },
      { policy: "cardUpsertCardHour", key: tenantResourceKey("t1", "card", "solar") },
    ]);
    await incrementRateLimitBuckets(env, [
      { policy: "cardUpsertCardHour", key: tenantResourceKey("t2", "card", "solar") },
    ]);

    const labels = (await listTenantRateLimitBuckets(env, "t1")).map((view) => view.label).sort();
    expect(labels).toEqual(["Card upserts", "Card upserts per card"]);
    await expect(listTenantRateLimitBuckets(env, "t2"))
      .resolves.toHaveLength(1);
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

describe("sweepExpiredRateLimitBuckets", () => {
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

  // No cron trigger is registered today, but the handler stays wired so
  // enabling one on Workers Paid is a config change and nothing else.
  it("is what the scheduled handler runs", async () => {
    const env = makeEnv();
    await incrementRateLimitBuckets(env, [
      { policy: "cardUpsertTenantHour", key: tenantKey("t1") },
    ]);
    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    await handler.scheduled!(scheduledEvent, env, executionCtx);
    // Both bounded sweeps: expired rate limit buckets and ended activities
    // past their retention window. Neither is urgent, so they share a tick.
    const swept = prepare.mock.calls.map(([sql]) => String(sql));
    expect(swept).toHaveLength(2);
    expect(swept[0]).toContain("DELETE FROM rate_limit_buckets");
    expect(swept[1]).toContain("DELETE FROM activity_history");
  });

  // Seeds distinct keys so the sweep has a backlog to chew through. Each key is
  // its own bucket row, which is exactly the shape orphaned per-resource
  // counters take in production.
  async function seedExpiredBuckets(env: Awaited<ReturnType<typeof makeEnv>>, count: number) {
    vi.setSystemTime(new Date("2026-08-17T10:00:00Z"));
    for (let index = 0; index < count; index += 1) {
      await incrementRateLimitBuckets(env, [
        { policy: "cardUpsertCardHour", key: `tenant:t1:card:c${index}` },
      ]);
    }
    // Past the two-window expires_at, so every row above is now collectable.
    vi.setSystemTime(new Date("2026-08-17T13:00:00Z"));
  }

  it("drains a backlog in chunks and stops on a short one", async () => {
    vi.useFakeTimers();
    const env = makeEnv();
    await seedExpiredBuckets(env, 1200);

    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    expect(await sweepExpiredRateLimitBuckets(env)).toBe(1200);
    // 500 + 500 + 200, and the short chunk ends the loop.
    expect(prepare).toHaveBeenCalledTimes(3);
  });

  // The property that matters is the ceiling, not the throughput: one call must
  // cost a bounded amount of work however far behind the table has fallen,
  // because the sweep is at its most expensive exactly when it matters most.
  it("stops at its chunk ceiling instead of draining the whole table", async () => {
    vi.useFakeTimers();
    const env = makeEnv();
    await seedExpiredBuckets(env, 5100);

    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    expect(await sweepExpiredRateLimitBuckets(env)).toBe(5000);
    expect(prepare).toHaveBeenCalledTimes(10);

    // The remainder is still there, and the next sweep takes it.
    expect(await sweepExpiredRateLimitBuckets(env)).toBe(100);
  });

  it("survives a failing sweep rather than failing its caller", async () => {
    const env = makeEnv();
    vi.spyOn(env.ZW_DB, "prepare").mockImplementation(() => {
      throw new Error("D1 unavailable");
    });
    await expect(handler.scheduled!(scheduledEvent, env, executionCtx)).resolves.toBeUndefined();
  });
});

describe("the queue consumer sweep", () => {
  function makeBatch(tenantIds: string[], settled: string[]) {
    return {
      queue: "zerozerowidget-widget-reloads",
      messages: tenantIds.map((tenantId, index) => ({
        id: `m${index}`,
        timestamp: new Date(),
        attempts: 1,
        body: { tenantId },
        ack() { settled.push(`ack:${tenantId}`); },
        retry() { settled.push(`retry:${tenantId}`); },
      })),
      ackAll() {},
      retryAll() {},
    } as unknown as MessageBatch<{ tenantId: string }>;
  }

  it("sweeps under waitUntil, and only after every message is settled", async () => {
    const env = makeEnv();
    await incrementRateLimitBuckets(env, [
      { policy: "cardUpsertTenantHour", key: tenantKey("t1") },
    ]);
    vi.spyOn(Math, "random").mockReturnValue(0);
    const prepare = vi.spyOn(env.ZW_DB, "prepare");

    const settled: string[] = [];
    const pending: Promise<unknown>[] = [];
    let settledWhenSwept = -1;
    const ctx = {
      waitUntil(task: Promise<unknown>) {
        settledWhenSwept = settled.length;
        pending.push(task);
      },
    } as unknown as ExecutionContext;

    await handler.queue!(makeBatch(["t1", "t2"], settled) as never, env, ctx);
    await Promise.all(pending);

    expect(settled).toEqual(["ack:t1", "ack:t2"]);
    // The sweep must not hold acks: by the time it is handed to waitUntil,
    // every message in the batch is already settled.
    expect(settledWhenSwept).toBe(2);
    // Two sweeps ride the same sampled tick — buckets and ended activities.
    expect(pending).toHaveLength(2);
    expect(prepare.mock.calls.filter(([sql]) => sql.includes("expires_at < ?"))).toHaveLength(2);
  });

  it("leaves the table alone when the sample misses", async () => {
    const env = makeEnv();
    vi.spyOn(Math, "random").mockReturnValue(0.99);
    const prepare = vi.spyOn(env.ZW_DB, "prepare");

    const settled: string[] = [];
    const pending: Promise<unknown>[] = [];
    const ctx = {
      waitUntil(task: Promise<unknown>) { pending.push(task); },
    } as unknown as ExecutionContext;

    await handler.queue!(makeBatch(["t1"], settled) as never, env, ctx);

    expect(settled).toEqual(["ack:t1"]);
    expect(pending).toHaveLength(0);
    expect(prepare.mock.calls.filter(([sql]) => sql.includes("expires_at < ?"))).toHaveLength(0);
  });
});

describe("rate limit headers", () => {
  const ctx = {} as ExecutionContext;
  const upsert = (env: ReturnType<typeof makeEnv>, id = "solar") =>
    (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify({ id, template: "summary", title: "Solar" }),
      }),
      env,
      ctx,
    );

  it("reports the remaining budget on a successful write", async () => {
    const env = makeEnv();
    const res = await upsert(env);
    expect(res.status).toBe(200);
    // The tightest bucket the request touched, which is the per-card one at 60.
    expect(res.headers.get("RateLimit-Limit")).toBe("60");
    expect(res.headers.get("RateLimit-Remaining")).toBe("59");
    expect(Number(res.headers.get("RateLimit-Reset"))).toBeGreaterThan(0);
  });

  it("counts down as the window is spent", async () => {
    const env = makeEnv();
    await upsert(env);
    const second = await upsert(env);
    expect(second.headers.get("RateLimit-Remaining")).toBe("58");
  });

  it("says nothing on a read that consumes no budget", async () => {
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", { method: "GET" }),
      makeEnv(),
      ctx,
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("RateLimit-Limit")).toBeNull();
  });

  it("does not leak one tenant's budget into another's response", async () => {
    // The snapshot is keyed on the per-request AuthContext, so a second
    // request in the same isolate must not see the first one's numbers.
    const env = makeEnv();
    await upsert(env, "a");
    await upsert(env, "a");
    const fresh = await upsert(env, "b");
    expect(fresh.headers.get("RateLimit-Remaining")).toBe("59");
  });
});
