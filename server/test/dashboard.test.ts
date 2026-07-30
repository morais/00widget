import { describe, expect, it } from "vitest";
import handler from "../src/index";
import { authedRequest, makeEnv } from "./helpers";

const executionCtx = {} as ExecutionContext;

describe("dashboard", () => {
  it("returns cards and deduplicated ongoing activities together", async () => {
    const env = makeEnv();
    const card = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify({
          id: "status",
          template: "summary",
          title: "Status",
          value: "Ready",
        }),
      }),
      env,
      executionCtx,
    );
    expect(card.status).toBe(200);

    const activity = await (handler.fetch as any)(
      authedRequest("https://x/v1/live-activities/start", {
        method: "POST",
        body: JSON.stringify({
          externalActivityId: "job-1",
          kind: "job",
          title: "Build",
          state: "running",
          progress: 0.25,
        }),
      }),
      env,
      executionCtx,
    );
    expect(activity.status).toBe(200);

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/dashboard", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);
    expect((await response.json()) as unknown).toMatchObject({
      cards: [{ id: "status", value: "Ready" }],
      activities: [{ externalActivityId: "job-1", state: "running" }],
    });
  });

  it("requires tenant authentication", async () => {
    const response = await (handler.fetch as any)(
      new Request("https://x/v1/dashboard"),
      makeEnv(),
      executionCtx,
    );
    expect(response.status).toBe(401);
  });
});
