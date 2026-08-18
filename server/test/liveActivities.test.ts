import { describe, it, expect } from "vitest";
import handler from "../src/index";
import { FieldLimits, StartLiveActivitySchema, UpdateLiveActivitySchema } from "../src/types";
import { makeEnv, authedRequest, seedApiKey } from "./helpers";
import { __resetApnsJwtCache } from "../src/apns";
import * as storage from "../src/storage";

const executionCtx = {} as ExecutionContext;

// Throwaway P-256 PKCS#8 — only used so APNs JWT signing reaches our fetch stub.
const TEST_P8 = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----`;

describe("live activities", () => {
  it("rejects live activity text beyond published limits", () => {
    expect(
      StartLiveActivitySchema.safeParse({
        externalActivityId: "washer-1",
        kind: "appliance",
        title: "Washer",
        state: "x".repeat(FieldLimits.activityState + 1),
      }).success,
    ).toBe(false);
    expect(
      UpdateLiveActivitySchema.safeParse({
        externalActivityId: "washer-1",
        alert: {
          title: "Done",
          body: "x".repeat(FieldLimits.alertBody + 1),
        },
      }).success,
    ).toBe(false);
    expect(
      StartLiveActivitySchema.safeParse({
        externalActivityId: "duplicate-items",
        kind: "appliance",
        title: "Composite",
        state: "running",
        items: [
          { id: "boiler", title: "Water" },
          { id: "boiler", title: "Water again" },
        ],
      }).success,
    ).toBe(false);
    expect(
      StartLiveActivitySchema.safeParse({
        externalActivityId: "too-many-items",
        kind: "appliance",
        title: "Composite",
        state: "running",
        items: Array.from(
          { length: FieldLimits.liveActivityItemCount + 1 },
          (_, index) => ({ id: `item-${index}`, title: `Item ${index}` }),
        ),
      }).success,
    ).toBe(false);
    expect(
      StartLiveActivitySchema.safeParse({
        externalActivityId: "countdown-minute",
        kind: "timer",
        title: "Estimate",
        state: "running",
        endsAt: "2026-07-30T14:30:00Z",
        countdownGranularity: "minute",
      }).success,
    ).toBe(true);
    expect(
      UpdateLiveActivitySchema.safeParse({
        externalActivityId: "countdown-second",
        countdownGranularity: "second",
      }).success,
    ).toBe(true);
    expect(
      UpdateLiveActivitySchema.safeParse({
        externalActivityId: "countdown-invalid",
        countdownGranularity: "hour",
      }).success,
    ).toBe(false);
  });

  it("stores composite item snapshots, preserves omitted items, and clears an empty snapshot", async () => {
    const env = makeEnv();
    const items = [
      {
        id: "boiler",
        title: "Water",
        icon: "flame.fill",
        value: "67",
        unit: "°C",
        subtitle: "Heating to 78°C",
        progress: 0.86,
        status: "running",
      },
      {
        id: "cooling",
        title: "Rooms",
        icon: "snowflake",
        value: "3",
        unit: "rooms",
        status: "running",
      },
    ];

    const start = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "solar-surplus-1",
          kind: "appliance",
          title: "Solar surplus",
          state: "running",
          icon: "sun.max.fill",
          items,
        }),
      }),
      env,
      executionCtx,
    );
    expect(start.status).toBe(200);

    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/update", {
        method: "POST",
        body: JSON.stringify({ externalActivityId: "solar-surplus-1", state: "optimizing" }),
      }),
      env,
      executionCtx,
    );
    let active = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    expect((await active.json()) as unknown).toMatchObject({
      activities: [{ state: "optimizing", items }],
    });

    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/update", {
        method: "POST",
        body: JSON.stringify({ externalActivityId: "solar-surplus-1", items: [] }),
      }),
      env,
      executionCtx,
    );
    active = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    expect((await active.json()) as unknown).toMatchObject({ activities: [{ items: [] }] });
  });

  it("rejects composite content that exceeds ActivityKit's combined 4 KB limit", async () => {
    const env = makeEnv();
    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "oversized-composite",
          kind: "appliance",
          title: "x".repeat(FieldLimits.title),
          state: "x".repeat(FieldLimits.activityState),
          subtitle: "x".repeat(FieldLimits.subtitle),
          items: Array.from({ length: FieldLimits.liveActivityItemCount }, (_, index) => ({
            id: `${index}-${"x".repeat(FieldLimits.id - 2)}`,
            title: "x".repeat(FieldLimits.title),
            subtitle: "x".repeat(FieldLimits.subtitle),
            icon: "x".repeat(FieldLimits.icon),
            value: "x".repeat(FieldLimits.value),
            unit: "x".repeat(FieldLimits.unit),
            progress: 0.5,
            status: "running",
          })),
        }),
      }),
      env,
      executionCtx,
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: "combined ActivityKit attributes and content state exceed 4096 bytes",
    });
  });

  it("carries a chart through start, update, and the stored session", async () => {
    const env = makeEnv();
    const start = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "queue-a",
          kind: "generic",
          title: "Queue",
          state: "waiting",
          value: "A61",
          chart: { points: [22, 20, 17, 15, 12, 9, 8, 6], reference: 10, style: "bar" },
        }),
      }),
      env,
      executionCtx,
    );
    expect(start.status).toBe(200);

    // An update that says nothing about the chart keeps the published one,
    // the way it keeps items.
    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/update", {
        method: "POST",
        body: JSON.stringify({ externalActivityId: "queue-a", value: "A62" }),
      }),
      env,
      executionCtx,
    );

    const list = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    const body = (await list.json()) as {
      activities: { value?: string; chart?: { points: number[]; reference?: number; style: string } }[];
    };
    const session = body.activities.find((a) => a.value === "A62");
    expect(session?.chart?.points).toEqual([22, 20, 17, 15, 12, 9, 8, 6]);
    expect(session?.chart?.reference).toBe(10);
    expect(session?.chart?.style).toBe("bar");
  });

  it("registers and lists pending", async () => {
    const env = makeEnv();

    const start = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-1",
          kind: "appliance",
          title: "Washer",
          state: "running",
          progress: 0.1,
          countdownGranularity: "minute",
        }),
      }),
      env,
      executionCtx,
    );
    expect(start.status).toBe(200);

    const pending = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/pending", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(pending.status).toBe(200);
    const data = (await pending.json()) as {
      activities: Array<{
        updatedAt?: string;
        startedAt?: string;
        icon?: string;
        endsAt?: string;
        countdownGranularity?: string;
      }>;
    };
    expect(data.activities).toHaveLength(1);
    expect(Date.parse(data.activities[0].updatedAt ?? "")).not.toBeNaN();
    expect(Date.parse(data.activities[0].startedAt ?? "")).not.toBeNaN();
    expect(data.activities[0].countdownGranularity).toBeUndefined();

    const active = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(active.status).toBe(200);
    expect((await active.json()) as unknown).toMatchObject({
      activities: [{
        externalActivityId: "washer-1",
        kind: "appliance",
        title: "Washer",
        state: "running",
        progress: 0.1,
      }],
    });
  });

  it("retains a registered activity when APNs is not configured", async () => {
    const env = makeEnv();

    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-1",
          kind: "appliance",
          title: "Washer",
          state: "running",
          progress: 0.1,
        }),
      }),
      env,
      executionCtx,
    );

    const reg = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/register", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "dev-1",
          localActivityId: "local-1",
          externalActivityId: "washer-1",
          kind: "appliance",
          pushToken: "deadbeef",
        }),
      }),
      env,
      executionCtx,
    );
    expect(reg.status).toBe(200);

    const afterRegister = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/pending", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(((await afterRegister.json()) as { activities: unknown[] }).activities).toHaveLength(0);

    const registered = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    expect((await registered.json()) as unknown).toMatchObject({
      activities: [{
        externalActivityId: "washer-1",
        kind: "appliance",
        title: "Washer",
        state: "running",
        progress: 0.1,
      }],
    });

    const update = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/update", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-1",
          state: "rinse",
          progress: 0.5,
        }),
      }),
      env,
      executionCtx,
    );
    expect(update.status).toBe(200);
    const updateBody = (await update.json()) as { apnsResult: { reason?: string } };
    // APNs is not configured in tests, so the helper reports as such.
    expect(updateBody.apnsResult.reason).toBe("apns-not-configured");

    const updated = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    expect((await updated.json()) as unknown).toMatchObject({
      activities: [{ state: "rinse", progress: 0.5 }],
    });

    const end = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/end", {
        method: "POST",
        body: JSON.stringify({ externalActivityId: "washer-1" }),
      }),
      env,
      executionCtx,
    );
    expect(end.status).toBe(502);

    const retained = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    expect((await retained.json()) as unknown).toMatchObject({
      activities: [{ externalActivityId: "washer-1", state: "rinse" }],
    });
  });

  it("retains a failed end delivery and deletes it after a successful retry", async () => {
    __resetApnsJwtCache();
    const env = makeEnv({
      APNS_TEAM_ID: "TEAMID1234",
      APNS_KEY_ID: "KEYID12345",
      APNS_PRIVATE_KEY: TEST_P8,
      APNS_BUNDLE_ID: "com.example.zerozerowidget",
    });

    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-retry-end",
          kind: "appliance",
          title: "Washer",
          state: "running",
        }),
      }),
      env,
      executionCtx,
    );
    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/register", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "dev-retry",
          localActivityId: "local-retry",
          externalActivityId: "washer-retry-end",
          kind: "appliance",
          pushToken: "aaaabbbbccccdddd",
        }),
      }),
      env,
      executionCtx,
    );

    const originalFetch = globalThis.fetch;
    let attempts = 0;
    globalThis.fetch = (async () => {
      attempts += 1;
      return attempts === 1
        ? new Response(JSON.stringify({ reason: "InternalServerError" }), { status: 500 })
        : new Response("{}", { status: 200 });
    }) as typeof fetch;
    try {
      const failedEnd = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/end", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "washer-retry-end" }),
        }),
        env,
        executionCtx,
      );
      expect(failedEnd.status).toBe(502);

      const retained = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities", { method: "GET" }),
        env,
        executionCtx,
      );
      expect((await retained.json()) as unknown).toMatchObject({
        activities: [{ externalActivityId: "washer-retry-end" }],
      });

      const successfulEnd = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/end", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "washer-retry-end" }),
        }),
        env,
        executionCtx,
      );
      expect(successfulEnd.status).toBe(200);
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(attempts).toBe(2);
    const ended = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    expect((await ended.json()) as { activities: unknown[] }).toEqual({ activities: [] });
  });

  it("ends an activity whose push token APNs reports as expired", async () => {
    // A Live Activity is ended by ActivityKit after eight hours, and its push
    // token dies with it. APNs then answers 410 ExpiredToken forever, so
    // treating that as retryable stranded the activity server-side with no way
    // to clear it — it kept appearing in the app as a phantom.
    __resetApnsJwtCache();
    const env = makeEnv({
      APNS_TEAM_ID: "TEAMID1234",
      APNS_KEY_ID: "KEYID12345",
      APNS_PRIVATE_KEY: TEST_P8,
      APNS_BUNDLE_ID: "com.example.zerozerowidget",
    });

    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-expired",
          kind: "appliance",
          title: "Washer",
          state: "running",
        }),
      }),
      env,
      executionCtx,
    );
    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/register", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "dev-expired",
          localActivityId: "local-expired",
          externalActivityId: "washer-expired",
          kind: "appliance",
          pushToken: "aaaabbbbccccdddd",
        }),
      }),
      env,
      executionCtx,
    );

    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ reason: "ExpiredToken" }), { status: 410 })) as typeof fetch;
    try {
      const res = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/end", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "washer-expired" }),
        }),
        env,
        executionCtx,
      );
      expect(res.status).toBe(200);
    } finally {
      globalThis.fetch = originalFetch;
    }

    const after = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    expect((await after.json()) as { activities: unknown[] }).toEqual({ activities: [] });
  });

  it("treats any 410 from APNs as a dead token, whatever reason it names", async () => {
    // Matching only on reason strings meant an unfamiliar one could strand an
    // activity permanently. The status alone is enough to know the token is
    // gone for good.
    __resetApnsJwtCache();
    const env = makeEnv({
      APNS_TEAM_ID: "TEAMID1234",
      APNS_KEY_ID: "KEYID12345",
      APNS_PRIVATE_KEY: TEST_P8,
      APNS_BUNDLE_ID: "com.example.zerozerowidget",
    });
    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-410",
          kind: "appliance",
          title: "Washer",
          state: "running",
        }),
      }),
      env,
      executionCtx,
    );
    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/register", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "dev-410",
          localActivityId: "local-410",
          externalActivityId: "washer-410",
          kind: "appliance",
          pushToken: "aaaabbbbccccdddd",
        }),
      }),
      env,
      executionCtx,
    );
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ reason: "SomethingApplePutThereLater" }), {
        status: 410,
      })) as typeof fetch;
    try {
      const res = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/end", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "washer-410" }),
        }),
        env,
        executionCtx,
      );
      expect(res.status).toBe(200);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("merges updates into pending activities before a push token exists", async () => {
    const env = makeEnv();

    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-pending",
          kind: "appliance",
          title: "Washer",
          state: "running",
          icon: "washer",
          endsAt: "2026-05-01T21:00:00Z",
          countdownGranularity: "minute",
          progress: 0.1,
        }),
      }),
      env,
      executionCtx,
    );

    const update = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/update", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-pending",
          state: "rinse",
          subtitle: "Rinse cycle",
          icon: "flame.fill",
          endsAt: "2026-05-01T21:30:00Z",
          progress: 0.5,
        }),
      }),
      env,
      executionCtx,
    );
    expect(update.status).toBe(200);
    expect(((await update.json()) as { pendingUpdated: boolean }).pendingUpdated).toBe(true);

    const pending = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/pending", { method: "GET" }),
      env,
      executionCtx,
    );
    const data = (await pending.json()) as {
      activities: Array<{
        state: string;
        subtitle?: string;
        icon?: string;
        progress?: number;
        endsAt?: string;
        countdownGranularity?: string;
      }>;
    };
    expect(data.activities).toHaveLength(1);
    expect(data.activities[0].state).toBe("rinse");
    expect(data.activities[0].subtitle).toBe("Rinse cycle");
    expect(data.activities[0].icon).toBe("flame.fill");
    expect(data.activities[0].progress).toBe(0.5);
    expect(data.activities[0].endsAt).toBe("2026-05-01T21:30:00Z");
    expect(data.activities[0].countdownGranularity).toBe("minute");
  });

  it("removes pending activities when they are ended before registration", async () => {
    const env = makeEnv();

    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-ended",
          kind: "appliance",
          title: "Washer",
          state: "running",
        }),
      }),
      env,
      executionCtx,
    );

    const end = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/end", {
        method: "POST",
        body: JSON.stringify({ externalActivityId: "washer-ended" }),
      }),
      env,
      executionCtx,
    );
    expect(end.status).toBe(200);

    const pending = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/pending", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(((await pending.json()) as { activities: unknown[] }).activities).toHaveLength(0);
  });

  it("isolates pending activities with the same external id across tenants", async () => {
    const env = makeEnv();
    await seedApiKey(env, "tenant-a-token", "tenant-a");
    await seedApiKey(env, "tenant-b-token", "tenant-b");

    for (const [token, title] of [
      ["tenant-a-token", "Washer A"],
      ["tenant-b-token", "Washer B"],
    ] as const) {
      const start = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/start", {
          method: "POST",
          body: JSON.stringify({
            externalActivityId: "shared-activity",
            kind: "appliance",
            title,
            state: "running",
          }),
        }, token),
        env,
        executionCtx,
      );
      expect(start.status).toBe(200);
    }

    const pendingA = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/pending", { method: "GET" }, "tenant-a-token"),
      env,
      executionCtx,
    );
    const pendingB = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/pending", { method: "GET" }, "tenant-b-token"),
      env,
      executionCtx,
    );

    expect(((await pendingA.json()) as { activities: Array<{ title: string }> }).activities).toMatchObject([
      { title: "Washer A" },
    ]);
    expect(((await pendingB.json()) as { activities: Array<{ title: string }> }).activities).toMatchObject([
      { title: "Washer B" },
    ]);
  });

  it("validates body shape", async () => {
    const env = makeEnv();
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/register", {
        method: "POST",
        body: JSON.stringify({ deviceId: "x" }),
      }),
      env,
      executionCtx,
    );
    expect(res.status).toBe(400);
  });

  it("registers a push-to-start token and reports it on /start", async () => {
    const env = makeEnv();

    const reg = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/register-start-token", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "dev-1",
          attributesType: "ZeroZeroWidgetActivityAttributes",
          pushToken: "cafef00ddeadbeef",
        }),
      }),
      env,
      executionCtx,
    );
    expect(reg.status).toBe(200);

    const start = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-2",
          kind: "appliance",
          title: "Washer",
          state: "running",
        }),
      }),
      env,
      executionCtx,
    );
    expect(start.status).toBe(200);
    const body = (await start.json()) as { pushToStartAttempted: number; apnsResults: unknown[] };
    // We have 1 token registered, so /start tries to push-start it once
    // (and falls back to apns-not-configured because no .p8 in tests).
    expect(body.pushToStartAttempted).toBe(1);
    expect(body.apnsResults).toHaveLength(1);
  });

  it("emits decodable complete content state for start, patch update, and end", async () => {
    __resetApnsJwtCache();
    const env = makeEnv({
      APNS_TEAM_ID: "TEAMID1234",
      APNS_KEY_ID: "KEYID12345",
      APNS_PRIVATE_KEY: TEST_P8,
      APNS_BUNDLE_ID: "com.example.zerozerowidget",
    });
    const captured: Array<{ aps: Record<string, any> }> = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (_input, init) => {
      captured.push(JSON.parse(String(init?.body)));
      return new Response("{}", { status: 200 });
    }) as typeof fetch;

    try {
      await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/register-start-token", {
          method: "POST",
          body: JSON.stringify({
            deviceId: "dev-wire",
            attributesType: "ZeroZeroWidgetActivityAttributes",
            pushToken: "cafef00dcafef00d",
          }),
        }),
        env,
        executionCtx,
      );

      await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/start", {
          method: "POST",
          body: JSON.stringify({
            externalActivityId: "washer-wire",
            kind: "appliance",
            title: "Washer",
            state: "running",
            subtitle: "Washing",
            items: [{
              id: "drum",
              title: "Drum",
              icon: "washer",
              value: "42",
              unit: "%",
              progress: 0.42,
              status: "running",
            }],
            endsAt: "2026-08-01T10:30:00Z",
            alert: { title: "Washer started", body: "Washing" },
          }),
        }),
        env,
        executionCtx,
      );

      await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/register", {
          method: "POST",
          body: JSON.stringify({
            deviceId: "dev-wire",
            localActivityId: "local-wire",
            externalActivityId: "washer-wire",
            kind: "appliance",
            pushToken: "deadbeefcafefeed",
          }),
        }),
        env,
        executionCtx,
      );

      await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/update", {
          method: "POST",
          body: JSON.stringify({
            externalActivityId: "washer-wire",
            subtitle: "Rinsing",
          }),
        }),
        env,
        executionCtx,
      );

      await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/end", {
          method: "POST",
          body: JSON.stringify({
            externalActivityId: "washer-wire",
            finalState: "finished",
          }),
        }),
        env,
        executionCtx,
      );
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(captured).toHaveLength(3);
    const startAps = captured[0].aps;
    expect(startAps.event).toBe("start");
    expect(startAps["input-push-token"]).toBe(1);
    expect(startAps.attributes.activityInstanceId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[4][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(startAps.alert).toEqual({ title: "Washer started", body: "Washing" });
    expect(startAps["content-state"]).toMatchObject({ state: "running", subtitle: "Washing" });
    expect(startAps["content-state"].items).toEqual([{
      id: "drum",
      title: "Drum",
      icon: "washer",
      value: "42",
      unit: "%",
      progress: 0.42,
      status: "running",
    }]);
    expect(startAps["content-state"].countdownGranularity).toBe("second");
    expect(typeof startAps["content-state"].updatedAt).toBe("number");
    expect(typeof startAps["content-state"].endsAt).toBe("number");

    const updateState = captured[1].aps["content-state"];
    expect(captured[1].aps.event).toBe("update");
    expect(updateState).toMatchObject({ state: "running", subtitle: "Rinsing" });
    expect(updateState.items).toEqual(startAps["content-state"].items);
    expect(updateState.countdownGranularity).toBe("second");
    expect(typeof updateState.updatedAt).toBe("number");
    expect(typeof updateState.endsAt).toBe("number");

    const endState = captured[2].aps["content-state"];
    expect(captured[2].aps.event).toBe("end");
    expect(captured[2].aps["dismissal-date"]).toBe(captured[2].aps.timestamp - 1);
    expect(endState).toMatchObject({ state: "finished", subtitle: "Rinsing" });
    expect(endState.items).toEqual(startAps["content-state"].items);
    expect(endState.countdownGranularity).toBe("second");
    expect(typeof endState.updatedAt).toBe("number");
    expect(typeof endState.endsAt).toBe("number");
  });

  it("fans updates and end pushes out to every registered device", async () => {
    __resetApnsJwtCache();
    const env = makeEnv({
      APNS_TEAM_ID: "TEAMID1234",
      APNS_KEY_ID: "KEYID12345",
      APNS_PRIVATE_KEY: TEST_P8,
      APNS_BUNDLE_ID: "com.example.zerozerowidget",
    });

    await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-multi",
          kind: "appliance",
          title: "Washer",
          state: "running",
        }),
      }),
      env,
      executionCtx,
    );

    for (const [deviceId, localActivityId, pushToken] of [
      ["device-a", "local-a", "aaaabbbbccccdddd"],
      ["device-b", "local-b", "1111222233334444"],
    ]) {
      const response = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/register", {
          method: "POST",
          body: JSON.stringify({
            deviceId,
            localActivityId,
            externalActivityId: "washer-multi",
            kind: "appliance",
            pushToken,
          }),
        }),
        env,
        executionCtx,
      );
      expect(response.status).toBe(200);
    }

    const listed = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", { method: "GET" }),
      env,
      executionCtx,
    );
    const listedData = (await listed.json()) as { activities: unknown[] };
    expect(listedData).toMatchObject({
      activities: [{ externalActivityId: "washer-multi", title: "Washer" }],
    });
    expect(listedData.activities).toHaveLength(1);

    const pushedTokens: string[] = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input) => {
      const url = typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : input.url;
      pushedTokens.push(new URL(url).pathname.split("/").pop() ?? "");
      return new Response("{}", { status: 200 });
    }) as typeof fetch;
    try {
      await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/update", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "washer-multi", state: "rinse" }),
        }),
        env,
        executionCtx,
      );
      await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/end", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "washer-multi", finalState: "finished" }),
        }),
        env,
        executionCtx,
      );
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(pushedTokens).toEqual([
      "aaaabbbbccccdddd",
      "1111222233334444",
      "aaaabbbbccccdddd",
      "1111222233334444",
    ]);
  });

  it("recovers a missing activity only on the requesting device", async () => {
    __resetApnsJwtCache();
    const env = makeEnv();
    await seedApiKey(
      env,
      "device-recovery-key",
      "test-tenant",
      "publisher",
      "device-session",
      "device-a",
      "2099-01-01T00:00:00.000Z",
      ["tenant:read", "device:register", "actions:run"],
    );

    for (const [deviceId, pushToken] of [
      ["device-a", "aaaabbbbccccdddd"],
      ["device-b", "1111222233334444"],
    ]) {
      const registered = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/register-start-token", {
          method: "POST",
          body: JSON.stringify({
            deviceId,
            attributesType: "ZeroZeroWidgetActivityAttributes",
            pushToken,
          }),
        }),
        env,
        executionCtx,
      );
      expect(registered.status).toBe(200);
    }

    const started = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "solar-recovery",
          kind: "appliance",
          title: "Solar surplus",
          state: "running",
          icon: "sun.max.fill",
          items: [{
            id: "boiler",
            title: "Water",
            value: "67",
            unit: "°C",
            progress: 0.86,
            status: "running",
          }],
        }),
      }),
      env,
      executionCtx,
    );
    const activityInstanceId = ((await started.json()) as { activityInstanceId: string })
      .activityInstanceId;

    Object.assign(env, {
      APNS_TEAM_ID: "TEAMID1234",
      APNS_KEY_ID: "KEYID12345",
      APNS_PRIVATE_KEY: TEST_P8,
      APNS_BUNDLE_ID: "com.example.zerozerowidget",
    });
    const captured: Array<{ url: string; body: Record<string, any> }> = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input, init) => {
      captured.push({
        url: typeof input === "string" ? input : input instanceof URL ? input.href : input.url,
        body: JSON.parse(String(init?.body)),
      });
      return new Response("{}", { status: 200 });
    }) as typeof fetch;

    try {
      const wrongDevice = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/recover", {
          method: "POST",
          body: JSON.stringify({ deviceId: "device-b", activityInstanceIds: [activityInstanceId] }),
        }, "device-recovery-key"),
        env,
        executionCtx,
      );
      expect(wrongDevice.status).toBe(403);

      const recovered = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/recover", {
          method: "POST",
          body: JSON.stringify({ deviceId: "device-a", activityInstanceIds: [activityInstanceId] }),
        }, "device-recovery-key"),
        env,
        executionCtx,
      );
      expect(recovered.status).toBe(200);
      expect(await recovered.json()).toEqual({ ok: true, recovered: [activityInstanceId] });
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(captured).toHaveLength(1);
    expect(captured[0].url).toContain("/3/device/aaaabbbbccccdddd");
    expect(captured[0].body.aps).toMatchObject({
      event: "start",
      attributes: {
        activityInstanceId,
        externalActivityId: "solar-recovery",
        title: "Solar surplus",
      },
      "content-state": {
        state: "running",
        items: [{ id: "boiler", title: "Water", value: "67", unit: "°C" }],
      },
    });
  });

  it("isolates identical external ids across owners, shares, and recipient-owned activities", async () => {
    __resetApnsJwtCache();
    const env = makeEnv({
      APNS_TEAM_ID: "TEAMID1234",
      APNS_KEY_ID: "KEYID12345",
      APNS_PRIVATE_KEY: TEST_P8,
      APNS_BUNDLE_ID: "com.example.zerozerowidget",
      SHARING_ENABLED: "true",
    });
    await seedApiKey(env, "owner-a-key", "owner-a");
    await seedApiKey(env, "owner-b-key", "owner-b");
    await seedApiKey(env, "recipient-key", "recipient");

    const shareA = await createAcceptedActivityShare(env, "owner-a-key", "recipient-key");
    const shareB = await createAcceptedActivityShare(env, "owner-b-key", "recipient-key");

    const instanceA = await startAndReadInstance(env, "owner-a-key", "Shared A");
    const instanceB = await startAndReadInstance(env, "owner-b-key", "Shared B");
    const recipientInstance = await startAndReadInstance(env, "recipient-key", "Recipient owned");
    expect(new Set([instanceA, instanceB, recipientInstance]).size).toBe(3);

    const ambiguousLegacyRegistration = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/register", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "legacy-device",
          localActivityId: "legacy-local",
          externalActivityId: "same-id",
          kind: "appliance",
          pushToken: "aaaabbbb9999",
        }),
      }, "recipient-key"),
      env,
      executionCtx,
    );
    expect(ambiguousLegacyRegistration.status).toBe(409);

    const foreignInstanceRegistration = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/register", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "foreign-device",
          localActivityId: "foreign-local",
          activityInstanceId: instanceB,
          externalActivityId: "same-id",
          kind: "appliance",
          pushToken: "aaaabbbb9998",
        }),
      }, "owner-a-key"),
      env,
      executionCtx,
    );
    expect(foreignInstanceRegistration.status).toBe(404);

    for (const [instanceId, pushToken] of [
      [instanceA, "aaaabbbb0001"],
      [instanceB, "aaaabbbb0002"],
      [recipientInstance, "aaaabbbb0003"],
    ]) {
      const registration = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/register", {
          method: "POST",
          body: JSON.stringify({
            deviceId: `device-${pushToken}`,
            localActivityId: `local-${pushToken}`,
            activityInstanceId: instanceId,
            externalActivityId: "same-id",
            kind: "appliance",
            pushToken,
          }),
        }, "recipient-key"),
        env,
        executionCtx,
      );
      expect(registration.status).toBe(200);
    }

    const before = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", {}, "recipient-key"),
      env,
      executionCtx,
    );
    const beforeActivities = ((await before.json()) as {
      activities: Array<{ activityInstanceId: string; externalActivityId: string }>;
    }).activities;
    expect(beforeActivities).toHaveLength(3);
    expect(beforeActivities.every((activity) => activity.externalActivityId === "same-id")).toBe(true);

    const pushedTokens: string[] = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async (input) => {
      const url = typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : input.url;
      pushedTokens.push(new URL(url).pathname.split("/").pop() ?? "");
      return new Response("{}", { status: 200 });
    }) as typeof fetch;
    try {
      env.SHARING_ENABLED = "false";
      const disabledShareUpdate = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/update", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "same-id", state: "suppressed" }),
        }, "owner-b-key"),
        env,
        executionCtx,
      );
      expect(disabledShareUpdate.status).toBe(200);
      expect(pushedTokens).toEqual([]);
      env.SHARING_ENABLED = "true";

      const updateA = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/update", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "same-id", state: "owner-a-update" }),
        }, "owner-a-key"),
        env,
        executionCtx,
      );
      expect(updateA.status).toBe(200);

      const updateRecipient = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/update", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "same-id", state: "recipient-update" }),
        }, "recipient-key"),
        env,
        executionCtx,
      );
      expect(updateRecipient.status).toBe(200);

      const endA = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/end", {
          method: "POST",
          body: JSON.stringify({ externalActivityId: "same-id" }),
        }, "owner-a-key"),
        env,
        executionCtx,
      );
      expect(endA.status).toBe(200);

      const revokeB = await (handler.fetch as any)(
        authedRequest(`https://x/v1/shares/${shareB}`, { method: "DELETE" }, "owner-b-key"),
        env,
        executionCtx,
      );
      expect(revokeB.status).toBe(200);
    } finally {
      globalThis.fetch = originalFetch;
    }

    expect(pushedTokens).toEqual([
      "aaaabbbb0001",
      "aaaabbbb0003",
      "aaaabbbb0001",
      "aaaabbbb0002",
    ]);
    const after = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", {}, "recipient-key"),
      env,
      executionCtx,
    );
    expect(((await after.json()) as {
      activities: Array<{ activityInstanceId: string }>;
    }).activities.map((activity) => activity.activityInstanceId)).toEqual([recipientInstance]);

    // Revoking one share cannot disturb the other owner record or the
    // recipient-owned instance, even though every external id is identical.
    expect(shareA).not.toBe(shareB);
    const ownerB = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities", {}, "owner-b-key"),
      env,
      executionCtx,
    );
    expect(((await ownerB.json()) as { activities: unknown[] }).activities).toHaveLength(1);
  });

  it("prunes start tokens that APNs rejects with BadDeviceToken", async () => {
    __resetApnsJwtCache();
    const env = makeEnv({
      APNS_TEAM_ID: "TEAMID1234",
      APNS_KEY_ID: "KEYID12345",
      APNS_PRIVATE_KEY: TEST_P8,
      APNS_BUNDLE_ID: "com.example.zerozerowidget",
    });

    const reg = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/register-start-token", {
        method: "POST",
        body: JSON.stringify({
          deviceId: "dev-dead",
          attributesType: "ZeroZeroWidgetActivityAttributes",
          pushToken: "deadbeefdead",
        }),
      }),
      env,
      executionCtx,
    );
    expect(reg.status).toBe(200);

    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ reason: "BadDeviceToken" }), {
        status: 400,
        headers: { "apns-id": "fake-apns-id" },
      })) as typeof fetch;
    try {
      const start = await (handler.fetch as any)(
        authedRequest("https://x/v1/live-activities/start", {
          method: "POST",
          body: JSON.stringify({
            externalActivityId: "washer-prune",
            kind: "appliance",
            title: "Washer",
            state: "running",
          }),
        }),
        env,
        executionCtx,
      );
      expect(start.status).toBe(200);
      const body = (await start.json()) as {
        pushToStartAttempted: number;
        apnsResults: Array<{ status: number; reason?: string }>;
      };
      expect(body.pushToStartAttempted).toBe(1);
      expect(body.apnsResults[0]).toMatchObject({ status: 400, reason: "BadDeviceToken" });
    } finally {
      globalThis.fetch = originalFetch;
    }

    // Re-trigger /start: the dead token should be gone, so push-to-start has
    // nothing to try.
    const second = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-prune-2",
          kind: "appliance",
          title: "Washer",
          state: "running",
        }),
      }),
      env,
      executionCtx,
    );
    expect(((await second.json()) as { pushToStartAttempted: number }).pushToStartAttempted).toBe(0);
  });

  it("falls back to pending-only when no start tokens are registered", async () => {
    const env = makeEnv();
    const start = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "washer-3",
          kind: "appliance",
          title: "Washer",
          state: "running",
        }),
      }),
      env,
      executionCtx,
    );
    expect(start.status).toBe(200);
    const body = (await start.json()) as { pushToStartAttempted: number };
    expect(body.pushToStartAttempted).toBe(0);
  });
});

async function createAcceptedActivityShare(
  env: ReturnType<typeof makeEnv>,
  ownerKey: string,
  recipientKey: string,
): Promise<string> {
  const create = await (handler.fetch as any)(
    authedRequest("https://x/v1/shares", {
      method: "POST",
      body: JSON.stringify({
        recipientEmail: "recipient@example.com",
        resourceKind: "activity_kind",
        resourceId: "appliance",
      }),
    }, ownerKey),
    env,
    executionCtx,
  );
  expect(create.status).toBe(201);
  const shareId = ((await create.json()) as { share: { id: string } }).share.id;
  const accept = await (handler.fetch as any)(
    authedRequest(`https://x/v1/shares/${shareId}/accept`, { method: "POST" }, recipientKey),
    env,
    executionCtx,
  );
  expect(accept.status).toBe(200);
  return shareId;
}

describe("activity instance lookups are tenant-scoped in the query", () => {
  it("getActivityInstanceForTarget refuses an instance the tenant is not a target of", async () => {
    const env = makeEnv();
    await seedApiKey(env, "owner-key", "tenant-owner");
    await seedApiKey(env, "stranger-key", "tenant-stranger");

    const instanceId = await startAndReadInstance(env, "owner-key", "Dishwasher");

    // The owner is a delivery target of its own instance.
    const asOwner = await storage.getActivityInstanceForTarget(env, instanceId, "tenant-owner");
    expect(asOwner?.activityInstanceId).toBe(instanceId);

    // An unrelated tenant gets nothing back, without the caller needing to
    // remember a follow-up authorization check.
    const asStranger = await storage.getActivityInstanceForTarget(
      env,
      instanceId,
      "tenant-stranger",
    );
    expect(asStranger).toBeNull();

    // A real id paired with the wrong tenant is indistinguishable from a
    // fabricated id, so the lookup leaks no existence signal either.
    const fabricated = await storage.getActivityInstanceForTarget(
      env,
      "00000000-0000-4000-8000-000000000000",
      "tenant-owner",
    );
    expect(fabricated).toBeNull();
  });
});

async function startAndReadInstance(
  env: ReturnType<typeof makeEnv>,
  apiKey: string,
  title: string,
): Promise<string> {
  const response = await (handler.fetch as any)(
    authedRequest("https://x/v1/live-activities/start", {
      method: "POST",
      body: JSON.stringify({
        externalActivityId: "same-id",
        kind: "appliance",
        title,
        state: "running",
      }),
    }, apiKey),
    env,
    executionCtx,
  );
  expect(response.status).toBe(200);
  return ((await response.json()) as { activityInstanceId: string }).activityInstanceId;
}
