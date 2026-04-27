import { describe, it, expect } from "vitest";
import handler from "../src/index";
import { makeEnv, authedRequest } from "./helpers";

const executionCtx = {} as ExecutionContext;

describe("live activities", () => {
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
      activities: Array<{ updatedAt?: string; startedAt?: string }>;
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
      activities: Array<{ state: string; subtitle?: string; progress?: number }>;
    };
    expect(data.activities).toHaveLength(1);
    expect(data.activities[0].state).toBe("rinse");
    expect(data.activities[0].subtitle).toBe("Rinse cycle");
    expect(data.activities[0].progress).toBe(0.5);
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
          pushToken: "startbeef",
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
