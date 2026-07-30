import { describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import { sha256Hex } from "../src/auth";
import * as storage from "../src/storage";
import {
  collectWidgetPushTargetsForCard,
  claimWidgetPushWindow,
  deliverWidgetReloads,
  enqueuePendingWidgetReload,
  getPendingWidgetReload,
  processPendingWidgetReload,
  scheduleWidgetReloadForCard,
} from "../src/widgetPush";
import { authedRequest, makeEnv } from "./helpers";

const executionCtx = {} as ExecutionContext;

describe("widget push subscriptions", () => {
  it("replaces a device snapshot and targets only subscribed cards", async () => {
    const env = makeEnv();
    const hash = await sha256Hex("test-key");
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

  it("claims at most one push window per tenant every thirty minutes", async () => {
    const env = makeEnv();
    await expect(claimWidgetPushWindow(env, "tenant-a", 10_000)).resolves.toBe(true);
    await expect(claimWidgetPushWindow(env, "tenant-a", 11_799)).resolves.toBe(false);
    await expect(claimWidgetPushWindow(env, "tenant-a", 11_800)).resolves.toBe(true);
    await expect(claimWidgetPushWindow(env, "tenant-b", 10_001)).resolves.toBe(true);
  });

  it("coalesces suppressed reloads and delivers them after the cadence window", async () => {
    const env = makeEnv();
    const hash = await sha256Hex("test-key");
    await storage.putWidgetToken(
      env,
      "test-tenant",
      hash,
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "aabbccdd",
    );
    await claimWidgetPushWindow(env, "test-tenant", 10_000);
    await enqueuePendingWidgetReload(env, "test-tenant", 10_001);
    await enqueuePendingWidgetReload(env, "test-tenant", 10_002);

    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toMatchObject({
      generation: 2,
      queuedAt: 10_002,
    });
    await expect(
      processPendingWidgetReload(env, { tenantId: "test-tenant" }, { nowSeconds: 11_799 }),
    ).resolves.toEqual({ delivered: false, retryAfterSeconds: 1 });

    const sender = vi.fn().mockResolvedValue({ status: 200, apnsId: "deferred" });
    await expect(
      processPendingWidgetReload(
        env,
        { tenantId: "test-tenant" },
        { nowSeconds: 11_800, sender },
      ),
    ).resolves.toEqual({ delivered: true });
    expect(sender).toHaveBeenCalledOnce();
    expect(sender).toHaveBeenCalledWith(env, "aabbccdd");
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toBeNull();
  });

  it("keeps a deferred reload durable after transient APNs failure", async () => {
    const env = makeEnv();
    const hash = await sha256Hex("test-key");
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
    await claimWidgetPushWindow(env, "test-tenant", 10_000);

    await enqueuePendingWidgetReload(env, "test-tenant", 10_001);
    await enqueuePendingWidgetReload(env, "test-tenant", 10_002);

    expect(queue.send).toHaveBeenCalledOnce();
    expect(queue.send).toHaveBeenCalledWith(
      { tenantId: "test-tenant" },
      { delaySeconds: 1_799 },
    );
    await expect(getPendingWidgetReload(env, "test-tenant")).resolves.toMatchObject({
      generation: 2,
    });
  });

  it("queues a second card change when the immediate push window is closed", async () => {
    const env = makeEnv();
    const hash = await sha256Hex("test-key");
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

  it("deduplicates one WidgetKit token across multiple widget kinds", async () => {
    const env = makeEnv();
    const hash = await sha256Hex("test-key");
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
    const hash = await sha256Hex("test-key");
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
    const hash = await sha256Hex("test-key");
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
