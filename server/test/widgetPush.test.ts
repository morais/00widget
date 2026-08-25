import { describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import { sha256Hex } from "../src/auth";
import * as storage from "../src/storage";
import {
  collectWidgetPushTargetsForCard,
  collectWidgetPushTargetsForCards,
  claimWidgetPushWindow,
  secondsUntilWidgetPushWindow,
  deliverWidgetReloads,
  enqueuePendingWidgetReload,
  getPendingWidgetReload,
  processPendingWidgetReload,
  scheduleWidgetReloadForCard,
  widgetPushApnsDiagnosticsEnabled,
} from "../src/widgetPush";
import { authedRequest, makeEnv, TEST_API_KEY } from "./helpers";

const executionCtx = {} as ExecutionContext;

describe("widget push subscriptions", () => {
  it("keeps APNs persistence off by default and enables it only explicitly", async () => {
    const off = makeEnv();
    expect(widgetPushApnsDiagnosticsEnabled(off)).toBe(false);
    const sender = vi.fn().mockResolvedValue({ status: 200, apnsId: "not-persisted" });
    await deliverWidgetReloads(
      off,
      [{ token: "aabbccdd", tenantIds: ["test-tenant"] }],
      { sender },
    );
    await expect(storage.listWidgetPushDeliveryDiagnostics(off, "test-tenant"))
      .resolves.toEqual([]);

    const on = makeEnv({ WIDGET_PUSH_APNS_DIAGNOSTICS: "true" });
    expect(widgetPushApnsDiagnosticsEnabled(on)).toBe(true);
    await storage.putWidgetToken(
      on,
      "test-tenant",
      await sha256Hex(TEST_API_KEY),
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "aabbccdd",
    );
    await deliverWidgetReloads(
      on,
      [{ token: "aabbccdd", tenantIds: ["test-tenant"] }],
      { sender: vi.fn().mockResolvedValue({ status: 200, apnsId: "accepted-id" }) },
    );
    await expect(storage.listWidgetPushDeliveryDiagnostics(on, "test-tenant"))
      .resolves.toMatchObject([{
        status: 200,
        apnsId: "accepted-id",
        attempts: 1,
      }]);
  });

  it("persists the final APNs failure after bounded retries", async () => {
    const env = makeEnv({ WIDGET_PUSH_APNS_DIAGNOSTICS: "true" });
    await storage.putWidgetToken(
      env,
      "test-tenant",
      await sha256Hex(TEST_API_KEY),
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "aabbccdd",
    );
    await deliverWidgetReloads(
      env,
      [{ token: "aabbccdd", tenantIds: ["test-tenant"] }],
      {
        sender: vi.fn().mockResolvedValue({ status: 503, reason: "ServiceUnavailable" }),
        sleep: async () => {},
      },
    );
    await expect(storage.listWidgetPushDeliveryDiagnostics(env, "test-tenant"))
      .resolves.toMatchObject([{
        status: 503,
        reason: "ServiceUnavailable",
        attempts: 3,
      }]);
  });

  it("replaces a device snapshot and targets only subscribed cards", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.replaceWidgetTokensForDevice(
      env,
      "test-tenant",
      hash,
      "device-1",
      "aabbccdd",
      [
        {
          widgetKind: "ZeroZeroWidgetCardWidget",
          cardIds: ["solar"],
          allCards: false,
        },
        {
          widgetKind: "ZeroZeroWidgetCardGridWidget",
          cardIds: ["washer"],
          allCards: false,
        },
      ],
    );

    await expect(storage.listWidgetTokensForCard(env, "test-tenant", "solar"))
      .resolves.toEqual(["aabbccdd"]);
    await expect(storage.listWidgetTokensForCard(env, "test-tenant", "washer"))
      .resolves.toEqual(["aabbccdd"]);
    await expect(storage.listWidgetTokensForCard(env, "test-tenant", "other"))
      .resolves.toEqual([]);

    await storage.replaceWidgetTokensForDevice(
      env,
      "test-tenant",
      hash,
      "device-1",
      "eeff0011",
      [{ widgetKind: "ZeroZeroWidgetCardWidget", cardIds: [], allCards: true }],
    );
    await expect(
      storage.listWidgetTokensForKind(env, "test-tenant", "ZeroZeroWidgetCardGridWidget"),
    ).resolves.toEqual([]);
    await expect(storage.listWidgetTokensForCard(env, "test-tenant", "anything"))
      .resolves.toEqual(["eeff0011"]);
  });

  it("accepts canonical sync and an empty snapshot invalidates the device", async () => {
    const env = makeEnv();
    const sync = await (handler.fetch as any)(
      authedRequest("https://x/v1/widgets/register-push-token", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "device-1",
          widgetPushToken: "aabbccdd",
          subscriptions: [
            {
              widgetKind: "ZeroZeroWidgetCardWidget",
              cardIds: ["solar"],
              allCards: false,
            },
          ],
          appVersion: "1.0 (202607292000)",
          platform: "ios",
        }),
      }),
      env,
      executionCtx,
    );
    expect(sync.status).toBe(200);
    await expect(storage.listWidgetTokensForCard(env, "test-tenant", "solar"))
      .resolves.toEqual(["aabbccdd"]);
    await expect(storage.listTenantWidgetTokens(env, "test-tenant")).resolves.toMatchObject([
      {
        value: {
          appVersion: "1.0 (202607292000)",
          platform: "ios",
        },
      },
    ]);

    const remove = await (handler.fetch as any)(
      authedRequest("https://x/v1/widgets/register-push-token", {
        method: "POST",
        body: JSON.stringify({ deviceId: "device-1", subscriptions: [] }),
      }),
      env,
      executionCtx,
    );
    expect(remove.status).toBe(200);
    await expect(storage.listWidgetTokens(env, "test-tenant")).resolves.toEqual([]);
  });

  it("spaces pushes to one widget by five minutes, and budgets each widget alone", async () => {
    const env = makeEnv();
    await expect(claimWidgetPushWindow(env, "token-a", 10_000)).resolves.toBe(true);
    await expect(claimWidgetPushWindow(env, "token-a", 10_299)).resolves.toBe(false);
    await expect(claimWidgetPushWindow(env, "token-a", 10_300)).resolves.toBe(true);
    // A second widget on the same device has its own allowance: Apple budgets
    // per widget instance, so one must never hold back another.
    await expect(claimWidgetPushWindow(env, "token-b", 10_001)).resolves.toBe(true);
  });

  it("bursts, then settles to the refill rate, and never runs dry", async () => {
    const env = makeEnv();
    // Claims at the minimum spacing until one is refused, which is what a
    // producer publishing flat out would experience.
    const drain = async (token: string, from: number) => {
      let at = from;
      let granted = 0;
      while (await claimWidgetPushWindow(env, token, at)) {
        granted += 1;
        at += 300;
      }
      return { granted, at };
    };

    // A burst is bounded — a producer cannot spend the day in five minutes —
    // but it is a real burst, not a single push.
    const first = await drain("token-a", 10_000);
    expect(first.granted).toBeGreaterThan(3);
    expect(first.granted).toBeLessThan(10);

    // The property a plain daily quota does not have, and the reason this is a
    // bucket. Forty pushes five minutes apart would exhaust a day in 3h20m and
    // leave the widget dark for the next twenty hours. Here the allowance keeps
    // coming back, one per refill period, for as long as the producer asks.
    let now = first.at;
    for (let i = 0; i < 5; i++) {
      now += 30 * 60;
      await expect(claimWidgetPushWindow(env, "token-a", now)).resolves.toBe(true);
    }

    // Idle time refills the bucket but does not overflow it: a day of quiet
    // buys no more than a few hours of it. Asserted as a cap rather than a
    // count, so the test states the guarantee instead of restating the rate.
    const burstAfterIdle = async (token: string, idleSeconds: number) => {
      const fresh = makeEnv();
      await claimWidgetPushWindow(fresh, token, 0);
      return (await (async () => {
        let at = idleSeconds;
        let granted = 0;
        while (await claimWidgetPushWindow(fresh, token, at)) {
          granted += 1;
          at += 300;
        }
        return granted;
      })());
    };
    expect(await burstAfterIdle("idle-6h", 6 * 60 * 60)).toBe(
      await burstAfterIdle("idle-24h", 24 * 60 * 60),
    );
  });

  it("does not let one widget's push hold back another on the same account", async () => {
    // The reason the cadence moved off the tenant. Apple budgets per widget
    // instance, so publishing to one must not stall the other.
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    for (const [device, token] of [["device-1", "aaaa"], ["device-2", "bbbb"]]) {
      await storage.putWidgetToken(env, "test-tenant", hash, device, "ZeroZeroWidgetCardWidget", token);
    }

    await expect(claimWidgetPushWindow(env, "aaaa", 10_000)).resolves.toBe(true);
    // The account is not "in a window" because one widget is: the second has
    // never been pushed, so a queued reload should wake now rather than sleep.
    await expect(secondsUntilWidgetPushWindow(env, "test-tenant", 10_001)).resolves.toBe(0);
    await expect(claimWidgetPushWindow(env, "bbbb", 10_001)).resolves.toBe(true);
    // With both just pushed, the wait is the sooner of the two spacings.
    await expect(secondsUntilWidgetPushWindow(env, "test-tenant", 10_002)).resolves.toBe(298);
  });

  it("coalesces suppressed reloads and delivers them after the cadence window", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.putWidgetToken(
      env,
      "test-tenant",
      hash,
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "aabbccdd",
    );
    await claimWidgetPushWindow(env, "aabbccdd", 10_000);
    await enqueuePendingWidgetReload(env, "test-tenant", 10_001);
    await enqueuePendingWidgetReload(env, "test-tenant", 10_002);

    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toMatchObject({
      generation: 2,
      queuedAt: 10_002,
    });
    await expect(
      processPendingWidgetReload(env, { tenantId: "test-tenant" }, { nowSeconds: 10_299 }),
    ).resolves.toEqual({ delivered: false, retryAfterSeconds: 1 });

    const sender = vi.fn().mockResolvedValue({ status: 200, apnsId: "deferred" });
    await expect(
      processPendingWidgetReload(
        env,
        { tenantId: "test-tenant" },
        { nowSeconds: 10_300, sender },
      ),
    ).resolves.toEqual({ delivered: true });
    expect(sender).toHaveBeenCalledOnce();
    expect(sender).toHaveBeenCalledWith(env, "aabbccdd");
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toBeNull();
  });

  it("keeps a deferred reload durable after transient APNs failure", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.putWidgetToken(
      env,
      "test-tenant",
      hash,
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "aabbccdd",
    );
    await enqueuePendingWidgetReload(env, "test-tenant", 10_000);

    const failed = vi.fn().mockResolvedValue({ status: 503, reason: "ServiceUnavailable" });
    await expect(
      processPendingWidgetReload(
        env,
        { tenantId: "test-tenant" },
        { nowSeconds: 10_000, sender: failed, sleep: async () => {} },
      ),
    ).resolves.toEqual({ delivered: false, retryAfterSeconds: 300 });
    expect(failed).toHaveBeenCalledTimes(3);
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.not.toBeNull();

    const recovered = vi.fn().mockResolvedValue({ status: 200, apnsId: "recovered" });
    await expect(
      processPendingWidgetReload(
        env,
        { tenantId: "test-tenant" },
        { nowSeconds: 11_800, sender: recovered },
      ),
    ).resolves.toEqual({ delivered: true });
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toBeNull();
  });

  it("schedules only one delayed queue message while reloads coalesce", async () => {
    const queue = { send: vi.fn().mockResolvedValue(undefined) };
    const env = { ...makeEnv(), WIDGET_RELOAD_QUEUE: queue } as unknown as ReturnType<typeof makeEnv>;
    // The delay is computed from the tenant's widgets, so there has to be one:
    // an account with no widget registered has nothing to wait for.
    await storage.putWidgetToken(
      env,
      "test-tenant",
      await sha256Hex(TEST_API_KEY),
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "aabbccdd",
    );
    await claimWidgetPushWindow(env, "aabbccdd", 10_000);

    await enqueuePendingWidgetReload(env, "test-tenant", 10_001);
    await enqueuePendingWidgetReload(env, "test-tenant", 10_002);

    expect(queue.send).toHaveBeenCalledOnce();
    expect(queue.send).toHaveBeenCalledWith(
      { tenantId: "test-tenant" },
      { delaySeconds: 299 },
    );
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toMatchObject({
      generation: 2,
    });
  });

  // The row is now claimed and inspected in one statement, so the decision to
  // send is made from what the write returned rather than from a separate read.
  it("reads the pending row once per enqueue", async () => {
    const env = makeEnv();
    await storage.putWidgetToken(
      env, "test-tenant", await sha256Hex(TEST_API_KEY),
      "device-1", "ZeroZeroWidgetCardWidget", "aabbccdd",
    );
    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    await enqueuePendingWidgetReload(env, "test-tenant", 10_001);

    const reads = prepare.mock.calls.filter(([sql]) =>
      sql.includes("FROM widget_push_pending") && sql.trim().startsWith("SELECT"));
    expect(reads, "the upsert already reports the generation").toHaveLength(0);
  });

  // Writing the row before sending means a failed send would strand it: the row
  // exists, so the next publish coalesces into it rather than scheduling its own
  // message, and the reload never goes out.
  it("removes the pending row it created when the queue send fails", async () => {
    const queue = { send: vi.fn().mockRejectedValue(new Error("queue unavailable")) };
    const env = { ...makeEnv(), WIDGET_RELOAD_QUEUE: queue } as unknown as ReturnType<typeof makeEnv>;
    await storage.putWidgetToken(
      env, "test-tenant", await sha256Hex(TEST_API_KEY),
      "device-1", "ZeroZeroWidgetCardWidget", "aabbccdd",
    );
    await claimWidgetPushWindow(env, "aabbccdd", 10_000);

    await expect(enqueuePendingWidgetReload(env, "test-tenant", 10_001)).rejects.toThrow();
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toBeNull();

    // So the next publish is the one that schedules, rather than assuming a
    // message it never sent is already in flight.
    queue.send.mockResolvedValue(undefined);
    await enqueuePendingWidgetReload(env, "test-tenant", 10_002);
    expect(queue.send).toHaveBeenCalledTimes(2);
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.not.toBeNull();
  });

  it("lists the tenant's widget tokens once per queue delivery", async () => {
    // Deliberately the partial-claim path: one widget has a slot and the other
    // does not, so the delivery runs to the end *and* computes a wait for the
    // one left behind. That is where the listing used to happen three times —
    // once for the opening wait, once to claim, once for the closing wait. The
    // paths that return early only ever listed once, so they cannot show this.
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.putWidgetToken(env, "test-tenant", hash, "device-1", "ZeroZeroWidgetCardWidget", "freshtok");
    await storage.putWidgetToken(env, "test-tenant", hash, "device-2", "ZeroZeroWidgetCardWidget", "spenttok");
    await claimWidgetPushWindow(env, "spenttok", 10_000);
    await enqueuePendingWidgetReload(env, "test-tenant", 10_001);

    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    const sender = vi.fn().mockResolvedValue({ status: 200, apnsId: "ok" });
    const outcome = await processPendingWidgetReload(
      env,
      { tenantId: "test-tenant" },
      { nowSeconds: 10_100, sender },
    );

    // The fresh widget was reloaded; the spent one still owes a push, so the
    // message comes back rather than the pending row being cleared.
    expect(sender).toHaveBeenCalledOnce();
    expect(sender).toHaveBeenCalledWith(env, "freshtok");
    expect(outcome.delivered).toBe(true);
    expect(outcome.retryAfterSeconds).toBeGreaterThan(0);

    const listings = prepare.mock.calls.filter(([sql]) =>
      sql.includes("SELECT token FROM widget_tokens"));
    expect(listings).toHaveLength(1);
  });

  // A tenant whose widgets sit on different cadences keeps the pending row
  // alive until the slowest can be served. Every wake used to re-claim the
  // whole token list, so a widget that still had budget was pushed again on its
  // own five-minute spacing — the same unchanged state, over and over, until
  // the queue exhausted max_retries and dropped the message. Those are reloads
  // out of Apple's 40-70 a day for that widget, which is the scarcest thing
  // this system spends.
  it("never re-pushes a widget that already carries the queued change", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.putWidgetToken(env, "test-tenant", hash, "d-fresh", "W", "freshtok");
    await storage.putWidgetToken(env, "test-tenant", hash, "d-spent", "W", "spenttok");

    // Drain one widget's bucket so it cannot be served for a long while.
    let at = 10_000;
    while (await claimWidgetPushWindow(env, "spenttok", at)) at += 300;
    await enqueuePendingWidgetReload(env, "test-tenant", at);

    const pushed: string[] = [];
    const sender = vi.fn().mockImplementation(async (_env: unknown, token: string) => {
      pushed.push(token);
      return { status: 200, apnsId: "ok" };
    });

    // Drive the redeliveries the queue would drive, following the delay each
    // one asks for.
    for (let round = 0; round < 6; round += 1) {
      const outcome = await processPendingWidgetReload(
        env, { tenantId: "test-tenant" }, { nowSeconds: at, sender },
      );
      if (!outcome.retryAfterSeconds) break;
      at += outcome.retryAfterSeconds;
    }

    // The fresh widget is served once and never again; the drained one is
    // served when its allowance finally refills.
    expect(pushed.filter((token) => token === "freshtok")).toHaveLength(1);
    expect(pushed).toContain("spenttok");
    // And once everyone carries it, the row is cleared rather than left to be
    // retried until the message is dropped.
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toBeNull();
  });

  it("clears a pending row whose widgets were all served by the publish itself", async () => {
    // The publish path can serve every widget and still record a pending row
    // (a transient APNs failure, say). Nothing is owed, so the next drain
    // should retire the row rather than push everyone a second time.
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.putWidgetToken(env, "test-tenant", hash, "d-1", "W", "tok1");
    await claimWidgetPushWindow(env, "tok1", 10_000);
    await enqueuePendingWidgetReload(env, "test-tenant", 10_000);

    const sender = vi.fn().mockResolvedValue({ status: 200, apnsId: "ok" });
    const outcome = await processPendingWidgetReload(
      env, { tenantId: "test-tenant" }, { nowSeconds: 10_000, sender },
    );

    expect(sender).not.toHaveBeenCalled();
    expect(outcome.retryAfterSeconds).toBeUndefined();
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toBeNull();
  });

  it("queues a second card change when the immediate push window is closed", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.putWidgetToken(
      env,
      "test-tenant",
      hash,
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "aabbccdd",
    );
    const pendingTasks: Promise<unknown>[] = [];
    const ctx = {
      waitUntil(task: Promise<unknown>) { pendingTasks.push(task); },
    } as ExecutionContext;

    scheduleWidgetReloadForCard(ctx, env, "test-tenant", "solar");
    await Promise.all(pendingTasks.splice(0));
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toBeNull();

    scheduleWidgetReloadForCard(ctx, env, "test-tenant", "solar");
    await Promise.all(pendingTasks.splice(0));
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toMatchObject({
      generation: 1,
    });
  });

  it("rejects subscriptions without a WidgetKit push token", async () => {
    const env = makeEnv();
    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/widgets/register-push-token", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "device-1",
          subscriptions: [
            {
              widgetKind: "ZeroZeroWidgetCardWidget",
              cardIds: ["solar"],
            },
          ],
        }),
      }),
      env,
      executionCtx,
    );
    expect(response.status).toBe(400);
  });

  it("rejects token-bearing empty snapshots without deleting registrations", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.replaceWidgetTokensForDevice(
      env,
      "test-tenant",
      hash,
      "device-1",
      "aabbccdd",
      [{ widgetKind: "ZeroZeroWidgetCardWidget", cardIds: ["solar"], allCards: false }],
    );

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/widgets/register-push-token", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "device-1",
          widgetPushToken: "aabbccdd",
          subscriptions: [],
        }),
      }),
      env,
      executionCtx,
    );

    expect(response.status).toBe(400);
    await expect(storage.listWidgetTokensForCard(env, "test-tenant", "solar"))
      .resolves.toEqual(["aabbccdd"]);
  });

  // The query behind a tenant's subscriptions names no card — which cards a
  // token wants is JSON on the row — so asking per card re-ran one tenant-wide
  // scan for every card in the snapshot.
  it("reads a tenant's widget subscriptions once per snapshot, not once per card", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.replaceWidgetTokensForDevice(
      env, "test-tenant", hash, "device-1", "aabbccdd",
      [{ widgetKind: "ZeroZeroWidgetCardWidget", cardIds: [], allCards: true }],
    );
    const prepare = vi.spyOn(env.ZW_DB, "prepare");

    const cardIds = Array.from({ length: 10 }, (_, i) => `ns.card${i}`);
    const targets = await collectWidgetPushTargetsForCards(env, "test-tenant", cardIds);

    expect(targets).toEqual([{ token: "aabbccdd", tenantIds: ["test-tenant"] }]);
    const scans = prepare.mock.calls.filter(([sql]) => sql.includes("FROM widget_tokens"));
    expect(scans, "ten cards, one tenant, one read").toHaveLength(1);
  });

  it("still targets only the tokens that asked for each card", async () => {
    // Reading once must not turn into pushing to everyone: the per-card match
    // moved from SQL into memory and has to keep the same answer.
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.replaceWidgetTokensForDevice(
      env, "test-tenant", hash, "device-solar", "solartoken",
      [{ widgetKind: "ZeroZeroWidgetCardWidget", cardIds: ["solar"], allCards: false }],
    );
    await storage.replaceWidgetTokensForDevice(
      env, "test-tenant", hash, "device-washer", "washertoken",
      [{ widgetKind: "ZeroZeroWidgetCardWidget", cardIds: ["washer"], allCards: false }],
    );
    await storage.replaceWidgetTokensForDevice(
      env, "test-tenant", hash, "device-all", "alltoken",
      [{ widgetKind: "ZeroZeroWidgetCardWidget", cardIds: [], allCards: true }],
    );

    const tokens = async (...cards: string[]) =>
      (await collectWidgetPushTargetsForCards(env, "test-tenant", cards))
        .map((target) => target.token).sort();

    expect(await tokens("solar")).toEqual(["alltoken", "solartoken"]);
    expect(await tokens("washer")).toEqual(["alltoken", "washertoken"]);
    expect(await tokens("unrelated")).toEqual(["alltoken"]);
    // A snapshot touching both reaches each once, not twice.
    expect(await tokens("solar", "washer")).toEqual(["alltoken", "solartoken", "washertoken"]);
  });

  it("deduplicates one WidgetKit token across multiple widget kinds", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.replaceWidgetTokensForDevice(
      env,
      "test-tenant",
      hash,
      "device-1",
      "aabbccdd",
      [
        { widgetKind: "ZeroZeroWidgetCardWidget", cardIds: ["solar"], allCards: false },
        { widgetKind: "ZeroZeroWidgetCardGridWidget", cardIds: ["solar"], allCards: false },
      ],
    );
    await expect(collectWidgetPushTargetsForCard(env, "test-tenant", "solar"))
      .resolves.toEqual([{ token: "aabbccdd", tenantIds: ["test-tenant"] }]);
  });

  it("moves a reused WidgetKit token to the current device snapshot", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.replaceWidgetTokensForDevice(
      env,
      "test-tenant",
      hash,
      "old-device",
      "aabbccdd",
      [{ widgetKind: "ZeroZeroWidgetCardWidget", cardIds: ["solar"], allCards: false }],
    );

    await storage.replaceWidgetTokensForDevice(
      env,
      "test-tenant",
      hash,
      "new-device",
      "aabbccdd",
      [{ widgetKind: "ZeroZeroWidgetCardWidget", cardIds: ["washer"], allCards: false }],
    );

    await expect(storage.listWidgetTokensForCard(env, "test-tenant", "solar"))
      .resolves.toEqual([]);
    await expect(storage.listWidgetTokensForCard(env, "test-tenant", "washer"))
      .resolves.toEqual(["aabbccdd"]);
    await expect(storage.listWidgetTokens(env, "test-tenant"))
      .resolves.toEqual(["aabbccdd"]);
  });

  it("retries transient failures and prunes permanently dead tokens", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.putWidgetToken(
      env,
      "test-tenant",
      hash,
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "aabbccdd",
    );
    const transientSender = vi
      .fn()
      .mockResolvedValueOnce({ status: 503, reason: "ServiceUnavailable" })
      .mockResolvedValueOnce({ status: 200, apnsId: "accepted" });
    const wait = vi.fn().mockResolvedValue(undefined);
    const retried = await deliverWidgetReloads(
      env,
      [{ token: "aabbccdd", tenantIds: ["test-tenant"] }],
      { sender: transientSender, sleep: wait },
    );
    expect(retried).toEqual([{ status: 200, apnsId: "accepted", attempts: 2 }]);
    expect(wait).toHaveBeenCalledOnce();

    const retryAfterWait = vi.fn().mockResolvedValue(undefined);
    const rateLimitedSender = vi
      .fn()
      .mockResolvedValueOnce({
        status: 429,
        reason: "TooManyRequests",
        retryAfterSeconds: 60,
      })
      .mockResolvedValueOnce({ status: 200, apnsId: "accepted-after-rate-limit" });
    const rateLimited = await deliverWidgetReloads(
      env,
      [{ token: "aabbccdd", tenantIds: ["test-tenant"] }],
      { sender: rateLimitedSender, sleep: retryAfterWait },
    );
    expect(rateLimited[0]).toMatchObject({ status: 200, attempts: 2 });
    expect(retryAfterWait).toHaveBeenCalledWith(5_000);

    const dead = await deliverWidgetReloads(
      env,
      [{ token: "aabbccdd", tenantIds: ["test-tenant"] }],
      { sender: async () => ({ status: 410, reason: "Unregistered" }) },
    );
    expect(dead[0]).toMatchObject({ status: 410, reason: "Unregistered", attempts: 1 });
    await expect(storage.listWidgetTokens(env, "test-tenant")).resolves.toEqual([]);
  });
});
