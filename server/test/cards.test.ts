import { describe, it, expect } from "vitest";
import handler from "../src/index";
import { DashboardCardSchema } from "../src/types";
import { sha256Hex } from "../src/auth";
import { makeEnv, authedRequest } from "./helpers";

const executionCtx = {} as ExecutionContext;

describe("DashboardCardSchema", () => {
  it("accepts a minimal metric card", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "solar-home",
      template: "metric",
      title: "Solar",
      value: "3.2",
      unit: "kW",
      status: "good",
    });
    expect(parsed.success).toBe(true);
  });

  it("rejects missing id/title", () => {
    expect(
      DashboardCardSchema.safeParse({ template: "metric", title: "x" }).success,
    ).toBe(false);
    expect(
      DashboardCardSchema.safeParse({ id: "a", template: "metric" }).success,
    ).toBe(false);
  });

  it("falls back to known defaults for unknown enum values", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "a",
      template: "exotic",
      title: "x",
      status: "plaid",
    });
    expect(parsed.success).toBe(true);
    if (parsed.success) {
      expect(parsed.data.template).toBe("status");
      expect(parsed.data.status).toBe("unknown");
    }
  });
});

describe("cards endpoints", () => {
  it("requires auth", async () => {
    const env = makeEnv();
    const res = await (handler.fetch as any)(new Request("https://x/v1/cards"), env, executionCtx);
    expect(res.status).toBe(401);
  });

  it("upserts and lists", async () => {
    const env = makeEnv();
    const body = {
      id: "solar-home",
      template: "metric",
      title: "Solar",
      value: "3.2",
      unit: "kW",
      status: "good",
    };
    const upsert = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", { method: "POST", body: JSON.stringify(body) }),
      env,
      executionCtx,
    );
    expect(upsert.status).toBe(200);

    const list = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(list.status).toBe(200);
    const data = (await list.json()) as { cards: unknown[] };
    expect(data.cards).toHaveLength(1);

    const del = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/solar-home", { method: "DELETE" }),
      env,
      executionCtx,
    );
    expect(del.status).toBe(200);

    const list2 = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", { method: "GET" }),
      env,
      executionCtx,
    );
    const data2 = (await list2.json()) as { cards: unknown[] };
    expect(data2.cards).toHaveLength(0);
  });

  it("lists cards by storage prefix instead of relying on the legacy index", async () => {
    const env = makeEnv();
    const hash = await sha256Hex("test-key");
    await env.ZW_KV.put(
      `card:${hash}:unindexed`,
      JSON.stringify({
        id: "unindexed",
        template: "status",
        title: "Unindexed",
        status: "good",
      }),
    );

    const list = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(list.status).toBe(200);
    const data = (await list.json()) as { cards: Array<{ id: string }> };
    expect(data.cards.map((c) => c.id)).toContain("unindexed");
  });

  it("health is public", async () => {
    const env = makeEnv();
    const res = await (handler.fetch as any)(new Request("https://x/health"), env, executionCtx);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });

  it("returns 400 on invalid body", async () => {
    const env = makeEnv();
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify({ template: "metric" }),
      }),
      env,
      executionCtx,
    );
    expect(res.status).toBe(400);
  });
});
