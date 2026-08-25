import { describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import * as storage from "../src/storage";
import { sha256Hex } from "../src/auth";
import { authedRequest, makeEnv, TEST_API_KEY } from "./helpers";

const ctx = {} as ExecutionContext;

async function status(env: ReturnType<typeof makeEnv>) {
  const res = await (handler.fetch as any)(
    authedRequest("https://x/v1/status", { method: "GET" }),
    env,
    ctx,
  );
  expect(res.status).toBe(200);
  return (await res.json()) as any;
}

describe("GET /v1/status", () => {
  it("reports that nothing can receive a publish when no device is registered", async () => {
    // The question the endpoint exists to answer. Without it a producer
    // publishes correctly into an account nobody is listening to and has no
    // way to find out.
    const body = await status(makeEnv());
    expect(body.delivery.canPushWidgets).toBe(false);
    expect(body.delivery.canStartLiveActivities).toBe(false);
    expect(body.delivery.devices).toBe(0);
  });

  // The endpoint already lists the tenant's widget tokens to count them, and
  // used to list them a second time computing the reload wait from the tenant
  // rather than from the list it was holding.
  it("lists the tenant's widget tokens once", async () => {
    const env = makeEnv();
    await storage.putWidgetToken(
      env, "test-tenant", await sha256Hex(TEST_API_KEY),
      "device-1", "ZeroZeroWidgetCardWidget", "aa",
    );
    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    await status(env);

    const listings = prepare.mock.calls.filter(([sql]) =>
      sql.includes("SELECT token FROM widget_tokens"));
    expect(listings).toHaveLength(1);
  });

  it("reports what a registered device can receive", async () => {
    const env = makeEnv();
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.putWidgetToken(env, "test-tenant", hash, "device-1", "ZeroZeroWidgetCardWidget", "aa");
    await storage.putStartToken(
      env,
      "test-tenant",
      hash,
      "device-1",
      "ZeroZeroWidgetActivityAttributes",
      "bb",
    );

    const body = await status(env);
    expect(body.delivery.canPushWidgets).toBe(true);
    expect(body.delivery.canStartLiveActivities).toBe(true);
    expect(body.delivery.widgetPushTokens).toBe(1);
  });

  it("states the reload cadence and how long until the next one", async () => {
    const body = await status(makeEnv());
    expect(body.delivery.widgetReloadMinSpacingSeconds).toBe(5 * 60);
    expect(body.delivery.widgetReloadBurst).toBe(6);
    expect(body.delivery.widgetReloadRefillSeconds).toBe(30 * 60);
    // Nothing has been published, so the window is open now.
    expect(body.delivery.secondsUntilNextWidgetReload).toBe(0);
    expect(body.delivery.widgetPushApnsDiagnosticsEnabled).toBe(false);
    expect(body.delivery.widgetPushLastDeliveries).toBeUndefined();
  });

  it("reports persisted APNs results only while diagnostics are enabled", async () => {
    const env = makeEnv({ WIDGET_PUSH_APNS_DIAGNOSTICS: "true" });
    const hash = await sha256Hex(TEST_API_KEY);
    await storage.putWidgetToken(
      env,
      "test-tenant",
      hash,
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "aabbccdd",
    );
    await storage.putWidgetPushDeliveryDiagnostic(env, "aabbccdd", {
      attemptedAt: "2026-08-21T12:20:41.000Z",
      status: 200,
      apnsId: "accepted-id",
      attempts: 1,
    });
    const body = await status(env);
    expect(body.delivery.widgetPushApnsDiagnosticsEnabled).toBe(true);
    expect(body.delivery.widgetPushLastDeliveries).toEqual([{
      tokenPrefix: "aabbccdd",
      attemptedAt: "2026-08-21T12:20:41.000Z",
      status: 200,
      apnsId: "accepted-id",
      attempts: 1,
    }]);
  });

  it("reports the credential's own scopes, so they need not be discovered by 403", async () => {
    const body = await status(makeEnv());
    expect(body.account.scopes).toContain("read");
    expect(body.account.tenantId).toBe("test-tenant");
    expect(typeof body.account.credentialExpiresAt).toBe("string");
  });

  it("counts what has been published", async () => {
    const env = makeEnv();
    await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify({ id: "solar", template: "summary", title: "Solar" }),
      }),
      env,
      ctx,
    );
    const body = await status(env);
    expect(body.published.cards).toBe(1);
    expect(body.published.liveActivities).toBe(0);
  });

  it("reports remaining rate-limit budget once a window has been touched", async () => {
    const env = makeEnv();
    await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify({ id: "solar", template: "summary", title: "Solar" }),
      }),
      env,
      ctx,
    );
    const body = await status(env);
    const upserts = body.rateLimits.find((entry: any) => entry.label === "Card upserts");
    expect(upserts).toBeTruthy();
    expect(upserts.remaining).toBe(upserts.limit - 1);
  });

  it("says whether this deployment sells and enforces subscriptions", async () => {
    const off = await status(makeEnv());
    expect(off.subscription).toEqual({ enabled: false, required: false });

    const on = await status(makeEnv({ SUBSCRIPTIONS_ENABLED: "true" } as any));
    expect(on.subscription.enabled).toBe(true);
    expect(on.subscription.required).toBe(false);
    expect(on.subscription.state).toBeTruthy();
  });
});


// Going quiet has no error, so this is where a producer finds out it has. Only
// exceptions are listed: a healthy account gets an empty array, the same rule
// `rateLimits` follows by reporting only windows the tenant has touched.
describe("GET /v1/status — activities needing attention", () => {
  const MINUTE = 60 * 1000;
  const hash = () => sha256Hex(TEST_API_KEY);

  async function seedOwned(
    env: ReturnType<typeof makeEnv>,
    id: string,
    fields: { updatedAt: string; staleAt?: string },
  ) {
    await storage.putActivityInstance(env, "test-tenant", await hash(), {
      activityInstanceId: id,
      externalActivityId: id,
      kind: "job",
      title: "Build",
      state: "running",
      ...fields,
    });
    await storage.putActivityTarget(env, id, "test-tenant", "test-tenant");
  }

  const attention = async (env: ReturnType<typeof makeEnv>) =>
    (await status(env)).attention.liveActivities as Array<Record<string, unknown>>;

  it("says nothing about an activity whose stale date is still ahead", async () => {
    const env = makeEnv();
    await seedOwned(env, "healthy", {
      updatedAt: new Date(Date.now() - 30 * MINUTE).toISOString(),
      staleAt: new Date(Date.now() + 30 * MINUTE).toISOString(),
    });

    expect(await attention(env)).toEqual([]);
  });

  it("reports an activity that outlived its own stale date", async () => {
    // The safety net worked — iOS is already drawing this as out of date — but
    // the run needs updating or ending.
    const env = makeEnv();
    await seedOwned(env, "overran", {
      updatedAt: new Date(Date.now() - 40 * MINUTE).toISOString(),
      staleAt: new Date(Date.now() - 10 * MINUTE).toISOString(),
    });

    expect(await attention(env)).toMatchObject([
      { externalActivityId: "overran", reason: "past-stale-date" },
    ]);
  });

  it("reports an activity that has gone quiet with no stale date at all", async () => {
    // The dangerous one: nothing will ever mark it stale, so the Lock Screen
    // shows its last state as current indefinitely.
    const env = makeEnv();
    await seedOwned(env, "silent", {
      updatedAt: new Date(Date.now() - 20 * MINUTE).toISOString(),
    });

    const [entry] = await attention(env);
    expect(entry).toMatchObject({ externalActivityId: "silent", reason: "no-stale-date", staleAt: null });
    expect(entry.secondsSinceUpdate as number).toBeGreaterThanOrEqual(20 * 60);
  });

  it("does not flag an activity that has only just started", async () => {
    // Without the quiet threshold, every status call right after a start would
    // report an activity seconds old as neglected.
    const env = makeEnv();
    await seedOwned(env, "fresh", { updatedAt: new Date().toISOString() });

    expect(await attention(env)).toEqual([]);
  });

  it("never reports an activity another tenant shared with this one", async () => {
    // It is visible here and this tenant cannot update it, so naming it would
    // be reporting somebody else's silence as this operator's neglect.
    const env = makeEnv();
    await storage.putActivityInstance(env, "other-tenant", "other-hash", {
      activityInstanceId: "theirs",
      externalActivityId: "theirs",
      kind: "job",
      title: "Their build",
      state: "running",
      updatedAt: new Date(Date.now() - 6 * 60 * MINUTE).toISOString(),
    });
    await storage.putActivityTarget(env, "theirs", "other-tenant", "test-tenant");

    // Visible in the count, absent from the attention list.
    const body = await status(env);
    expect(body.published.liveActivities).toBe(1);
    expect(body.attention.liveActivities).toEqual([]);
  });
});
