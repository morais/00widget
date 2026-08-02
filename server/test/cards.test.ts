import { describe, it, expect } from "vitest";
import handler from "../src/index";
import {
  DashboardCardInputSchema,
  DashboardCardSchema,
  FieldLimits,
  RequestBodyLimits,
} from "../src/types";
import { sha256Hex } from "../src/auth";
import { makeEnv, authedRequest, seedApiKey } from "./helpers";
import * as storage from "../src/storage";

const executionCtx = {} as ExecutionContext;

describe("DashboardCardSchema", () => {
  it("accepts a minimal summary card", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "solar-home",
      template: "summary",
      title: "Solar",
      value: "3.2",
      unit: "kW",
      status: "good",
    });
    expect(parsed.success).toBe(true);
  });

  it("rejects missing id/title", () => {
    expect(
      DashboardCardSchema.safeParse({ template: "summary", title: "x" }).success,
    ).toBe(false);
    expect(
      DashboardCardSchema.safeParse({ id: "a", template: "summary" }).success,
    ).toBe(false);
  });

  it("rejects unknown template values", () => {
    expect(DashboardCardSchema.safeParse({ id: "a", template: "exotic", title: "x" }).success).toBe(false);
  });

  it("defaults unknown status values", () => {
    const statusParsed = DashboardCardSchema.safeParse({
      id: "a",
      template: "summary",
      title: "x",
      status: "plaid",
    });
    expect(statusParsed.success).toBe(true);
    if (statusParsed.success) expect(statusParsed.data.status).toBe("unknown");
  });

  it("rejects fields and arrays beyond published limits", () => {
    expect(
      DashboardCardInputSchema.safeParse({
        id: "a".repeat(FieldLimits.cardId + 1),
        template: "summary",
        title: "x",
      }).success,
    ).toBe(false);
    expect(
      DashboardCardSchema.safeParse({
        id: "a",
        template: "list",
        title: "x",
        items: Array.from({ length: FieldLimits.itemCount + 1 }, (_, index) => ({
          id: `item-${index}`,
          title: "Item",
        })),
      }).success,
    ).toBe(false);
    expect(
      DashboardCardInputSchema.safeParse({
        id: "a",
        template: "action",
        title: "x",
        actions: Array.from({ length: FieldLimits.actionCount + 1 }, (_, index) => ({
          id: `action-${index}`,
          label: "Run",
        })),
      }).success,
    ).toBe(false);
  });

  it("strips write-only payloads from the public card schema", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "a",
      template: "action",
      title: "Controls",
      actions: [{ id: "run", label: "Run", payload: { secret: "do-not-return" } }],
    });
    expect(parsed.success).toBe(true);
    if (parsed.success) expect(parsed.data.actions?.[0]).not.toHaveProperty("payload");
  });

  it("rejects oversized action payloads", () => {
    const payload = Object.fromEntries(
      Array.from({ length: FieldLimits.actionPayloadKeys + 1 }, (_, index) => [
        `key-${index}`,
        "x",
      ]),
    );
    expect(
      DashboardCardInputSchema.safeParse({
        id: "a",
        template: "action",
        title: "x",
        actions: [{ id: "run", label: "Run", payload }],
      }).success,
    ).toBe(false);
  });

  it("rejects unknown action roles instead of making them widget-safe", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "a",
      template: "action",
      title: "Controls",
      actions: [{ id: "run", label: "Run", role: "unexpected" }],
    });

    expect(parsed.success).toBe(false);
  });

  it("accepts only HTTPS deep links", () => {
    const card = {
      id: "a",
      template: "summary",
      title: "Status",
    };

    expect(
      DashboardCardSchema.safeParse({ ...card, deepLink: "https://example.com/status" }).success,
    ).toBe(true);
    for (const deepLink of [
      "http://example.com/status",
      "widget-admin://reset",
      "javascript:alert(1)",
    ]) {
      expect(DashboardCardSchema.safeParse({ ...card, deepLink }).success).toBe(false);
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
      template: "summary",
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

  it("extracts action payloads before cards reach any read response", async () => {
    const env = makeEnv();
    const body = {
      id: "private-action",
      template: "action",
      title: "Private action",
      actions: [{
        id: "run-private",
        label: "Run",
        payload: { accessToken: "must-not-leave-server" },
      }],
    };
    const upsert = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify(body),
      }),
      env,
      executionCtx,
    );
    expect(upsert.status).toBe(200);

    const responses = [
      await upsert.json(),
      await (await (handler.fetch as any)(
        authedRequest("https://x/v1/cards/private-action"),
        env,
        executionCtx,
      )).json(),
      await (await (handler.fetch as any)(
        authedRequest("https://x/v1/cards"),
        env,
        executionCtx,
      )).json(),
      await (await (handler.fetch as any)(
        authedRequest("https://x/v1/dashboard"),
        env,
        executionCtx,
      )).json(),
    ];
    for (const response of responses) {
      expect(JSON.stringify(response)).not.toContain("must-not-leave-server");
      expect(JSON.stringify(response)).not.toContain("accessToken");
    }
    await expect(
      storage.getActionPayload(env, "test-tenant", "private-action", "run-private"),
    ).resolves.toEqual({ accessToken: "must-not-leave-server" });

    await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify({
          ...body,
          actions: [{ id: "run-private", label: "Run" }],
        }),
      }),
      env,
      executionCtx,
    );
    await expect(
      storage.getActionPayload(env, "test-tenant", "private-action", "run-private"),
    ).resolves.toBeNull();
  });

  it("upserts a card batch and schedules one coalesced widget reload", async () => {
    const env = makeEnv();
    const pending: Promise<unknown>[] = [];
    const ctx = {
      waitUntil(task: Promise<unknown>) { pending.push(task); },
    } as ExecutionContext;
    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert-batch", {
        method: "POST",
        body: JSON.stringify({
          cards: [
            { id: "api-status", template: "summary", title: "API", value: "Healthy" },
            { id: "queue-depth", template: "summary", title: "Queue", value: "12" },
            {
              id: "database-status",
              template: "action",
              title: "Database",
              actions: [{ id: "restart", label: "Restart", payload: { node: "primary" } }],
            },
          ],
        }),
      }),
      env,
      ctx,
    );

    expect(response.status).toBe(200);
    const responseBody = (await response.json()) as { cards: unknown[] };
    expect(responseBody.cards).toHaveLength(3);
    expect(JSON.stringify(responseBody)).not.toContain("primary");
    expect(pending).toHaveLength(1);
    await Promise.all(pending);
    await expect(storage.listCards(env, "test-tenant")).resolves.toHaveLength(3);
    await expect(
      storage.getActionPayload(env, "test-tenant", "database-status", "restart"),
    ).resolves.toEqual({ node: "primary" });
  });

  it("rejects duplicate ids in a card batch", async () => {
    const env = makeEnv();
    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert-batch", {
        method: "POST",
        body: JSON.stringify({
          cards: [
            { id: "same", template: "summary", title: "First" },
            { id: "same", template: "summary", title: "Second" },
          ],
        }),
      }),
      env,
      executionCtx,
    );
    expect(response.status).toBe(400);
  });

  it("schedules a widget reload when a card is deleted", async () => {
    const env = makeEnv();
    const hash = await sha256Hex("test-key");
    await storage.putCard(env, "test-tenant", hash, {
      id: "solar-home",
      template: "action",
      title: "Solar",
      status: "good",
      actions: [{
        id: "disconnect",
        label: "Disconnect",
        role: "normal",
        confirm: false,
        payload: { relay: "main" },
      }],
    });
    await expect(
      storage.getActionPayload(env, "test-tenant", "solar-home", "disconnect"),
    ).resolves.toEqual({ relay: "main" });
    await storage.putWidgetToken(
      env,
      "test-tenant",
      hash,
      "device-1",
      "ZeroZeroWidgetCardWidget",
      "feedface",
    );
    const pending: Promise<unknown>[] = [];
    const ctx = {
      waitUntil(task: Promise<unknown>) { pending.push(task); },
    } as ExecutionContext;

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/solar-home", { method: "DELETE" }),
      env,
      ctx,
    );

    expect(response.status).toBe(200);
    expect(pending).toHaveLength(1);
    await Promise.all(pending);
    await expect(storage.getCard(env, "test-tenant", "solar-home")).resolves.toBeNull();
    await expect(
      storage.getActionPayload(env, "test-tenant", "solar-home", "disconnect"),
    ).resolves.toBeNull();
  });

  it("isolates cards with the same id across tenants", async () => {
    const env = makeEnv();
    await seedApiKey(env, "tenant-a-token", "tenant-a");
    await seedApiKey(env, "tenant-b-token", "tenant-b");

    const cardA = {
      id: "shared-card",
      template: "summary",
      title: "Tenant A",
      value: "1",
    };
    const cardB = {
      id: "shared-card",
      template: "summary",
      title: "Tenant B",
      value: "2",
    };

    expect(
      (await (handler.fetch as any)(
        authedRequest("https://x/v1/cards/upsert", { method: "POST", body: JSON.stringify(cardA) }, "tenant-a-token"),
        env,
        executionCtx,
      )).status,
    ).toBe(200);
    expect(
      (await (handler.fetch as any)(
        authedRequest("https://x/v1/cards/upsert", { method: "POST", body: JSON.stringify(cardB) }, "tenant-b-token"),
        env,
        executionCtx,
      )).status,
    ).toBe(200);

    const listA = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", { method: "GET" }, "tenant-a-token"),
      env,
      executionCtx,
    );
    const listB = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", { method: "GET" }, "tenant-b-token"),
      env,
      executionCtx,
    );

    expect(((await listA.json()) as { cards: Array<{ title: string }> }).cards).toMatchObject([
      { title: "Tenant A" },
    ]);
    expect(((await listB.json()) as { cards: Array<{ title: string }> }).cards).toMatchObject([
      { title: "Tenant B" },
    ]);
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
        body: JSON.stringify({ template: "summary" }),
      }),
      env,
      executionCtx,
    );
    expect(res.status).toBe(400);
  });

  it("returns 400 when card body exceeds the request limit", async () => {
    const env = makeEnv();
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify({
          id: "too-large",
          template: "summary",
          title: "x",
          subtitle: "x".repeat(RequestBodyLimits.card),
        }),
      }),
      env,
      executionCtx,
    );
    expect(res.status).toBe(400);
  });

  it("returns 429 when a card id exceeds its hourly upsert limit", async () => {
    const env = makeEnv();
    let res: Response | null = null;
    for (let i = 0; i < 61; i++) {
      res = await (handler.fetch as any)(
        authedRequest("https://x/v1/cards/upsert", {
          method: "POST",
          body: JSON.stringify({
            id: "hot-card",
            template: "summary",
            title: "Hot card",
            value: String(i),
          }),
        }),
        env,
        executionCtx,
      );
    }
    expect(res?.status).toBe(429);
    expect(res?.headers.get("retry-after")).toBeTruthy();
    expect(await res!.json()).toMatchObject({
      error: "rate limit exceeded",
      limit: 60,
      windowSeconds: 3600,
    });
  });

  it("filters widget push tokens by widget kind", async () => {
    const env = makeEnv();
    const hash = await sha256Hex("test-key");

    await storage.putWidgetToken(env, "test-tenant", hash, "device-1", "ZeroZeroWidgetCardWidget", "card-token");
    await storage.putWidgetToken(env, "test-tenant", hash, "device-2", "ZeroZeroWidgetCardGridWidget", "grid-token");

    await expect(
      storage.listWidgetTokensForKind(env, "test-tenant", "ZeroZeroWidgetCardWidget"),
    ).resolves.toEqual(["card-token"]);
  });

  it("filters widget push tokens by tenant and widget kind", async () => {
    const env = makeEnv();
    const hashA = await sha256Hex("tenant-a-token");
    const hashB = await sha256Hex("tenant-b-token");

    await storage.putWidgetToken(env, "tenant-a", hashA, "device-a", "ZeroZeroWidgetCardWidget", "card-a");
    await storage.putWidgetToken(env, "tenant-b", hashB, "device-b", "ZeroZeroWidgetCardWidget", "card-b");

    await expect(
      storage.listWidgetTokensForKind(env, "tenant-a", "ZeroZeroWidgetCardWidget"),
    ).resolves.toEqual(["card-a"]);
  });
});
