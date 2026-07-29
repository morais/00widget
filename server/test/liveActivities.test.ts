import { describe, it, expect } from "vitest";
import handler from "../src/index";
import { FieldLimits, StartLiveActivitySchema, UpdateLiveActivitySchema } from "../src/types";
import { makeEnv, authedRequest, seedApiKey } from "./helpers";
import { __resetApnsJwtCache } from "../src/apns";

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
      activities: Array<{ updatedAt?: string; startedAt?: string; icon?: string; endsAt?: string }>;
    };
    expect(data.activities).toHaveLength(1);
    expect(Date.parse(data.activities[0].updatedAt ?? "")).not.toBeNaN();
    expect(Date.parse(data.activities[0].startedAt ?? "")).not.toBeNaN();
  });

  it("registers a push token and ends without APNs configured", async () => {
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

    const end = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/end", {
        method: "POST",
        body: JSON.stringify({ externalActivityId: "washer-1" }),
      }),
      env,
      executionCtx,
    );
    expect(end.status).toBe(200);
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
      activities: Array<{ state: string; subtitle?: string; icon?: string; progress?: number; endsAt?: string }>;
    };
    expect(data.activities).toHaveLength(1);
    expect(data.activities[0].state).toBe("rinse");
    expect(data.activities[0].subtitle).toBe("Rinse cycle");
    expect(data.activities[0].icon).toBe("flame.fill");
    expect(data.activities[0].progress).toBe(0.5);
    expect(data.activities[0].endsAt).toBe("2026-05-01T21:30:00Z");
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
    expect(startAps.alert).toEqual({ title: "Washer started", body: "Washing" });
    expect(startAps["content-state"]).toMatchObject({ state: "running", subtitle: "Washing" });
    expect(typeof startAps["content-state"].updatedAt).toBe("number");
    expect(typeof startAps["content-state"].endsAt).toBe("number");

    const updateState = captured[1].aps["content-state"];
    expect(captured[1].aps.event).toBe("update");
    expect(updateState).toMatchObject({ state: "running", subtitle: "Rinsing" });
    expect(typeof updateState.updatedAt).toBe("number");
    expect(typeof updateState.endsAt).toBe("number");

    const endState = captured[2].aps["content-state"];
    expect(captured[2].aps.event).toBe("end");
    expect(captured[2].aps["dismissal-date"]).toBe(captured[2].aps.timestamp - 1);
    expect(endState).toMatchObject({ state: "finished", subtitle: "Rinsing" });
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
