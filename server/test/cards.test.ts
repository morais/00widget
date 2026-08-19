import { describe, it, expect } from "vitest";
import handler from "../src/index";
import {
  DashboardCardInputSchema,
  DashboardCardSchema,
  FieldLimits,
  RequestBodyLimits,
} from "../src/types";
import { sha256Hex } from "../src/auth";
import { makeEnv, authedRequest, seedApiKey, TEST_API_KEY } from "./helpers";
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

  it("requires input dates to be full ISO-8601 instants", () => {
    const card = (staleAfter: string) => ({
      id: "a",
      template: "summary" as const,
      title: "x",
      staleAfter,
    });
    for (const good of [
      "2026-04-26T18:45:00Z",
      "2026-04-26T18:45:00.123Z",
      "2026-04-26T19:45:00+01:00",
    ]) {
      expect(DashboardCardInputSchema.safeParse(card(good)).success, good).toBe(true);
    }
    // Every one of these was accepted before, stored, echoed back on read, and
    // then decoded to nil by ISO8601DateFormatter on the device.
    for (const bad of [
      "2026-04-26",
      "2026-04-26T18:45:00",
      "April 26 2026",
      "2026-04-26 18:45:00Z",
      "2026-13-45T99:99:99Z",
    ]) {
      expect(DashboardCardInputSchema.safeParse(card(bad)).success, bad).toBe(false);
    }
  });

  it("still reads a stored card whose dates predate that rule", () => {
    // storage.getCard re-validates every row it loads. One legacy date must not
    // fail the read and take the whole list down with it.
    const parsed = DashboardCardSchema.safeParse({
      id: "a",
      template: "summary",
      title: "x",
      updatedAt: "2026-04-26",
      staleAfter: "2026-04-26",
    });
    expect(parsed.success).toBe(true);
  });

  it("rejects ids that cannot survive a URL path segment", () => {
    const card = (id: string) => ({ id, template: "summary" as const, title: "x" });
    for (const good of ["solar-home", "myapp.build_status", "school-balance:child-1", "473"]) {
      expect(DashboardCardInputSchema.safeParse(card(good)).success, good).toBe(true);
    }
    // Each of these used to publish successfully and then be unreachable by
    // `GET`/`DELETE /v1/cards/<id>`, because the route pattern is `([^/]+)`
    // and the segment was never decoded.
    for (const bad of ["a/b", "my card", "a?b", "a#b", "a%2Fb"]) {
      expect(DashboardCardInputSchema.safeParse(card(bad)).success, bad).toBe(false);
    }
  });

  it("rejects action ids that cannot survive a URL path segment", () => {
    const withAction = (id: string) => ({
      id: "boiler",
      template: "action" as const,
      title: "Boiler",
      actions: [{ id, label: "Boost" }],
    });
    expect(DashboardCardInputSchema.safeParse(withAction("boost-1h")).success).toBe(true);
    expect(DashboardCardInputSchema.safeParse(withAction("boost 1h")).success).toBe(false);
  });

  it("still reads a stored card whose id predates that rule", () => {
    const parsed = DashboardCardSchema.safeParse({ id: "a/b", template: "summary", title: "x" });
    expect(parsed.success).toBe(true);
  });

  it("accepts a numeric progress alongside a display value", () => {
    const parsed = DashboardCardInputSchema.safeParse({
      id: "test-suite",
      template: "progress",
      title: "Test suite",
      value: "184 of 240",
      progress: 0.767,
    });
    expect(parsed.success).toBe(true);
    expect(parsed.success && parsed.data.progress).toBe(0.767);
  });

  it("rejects a progress outside 0-1", () => {
    const card = (progress: number) => ({
      id: "a",
      template: "progress" as const,
      title: "x",
      progress,
    });
    expect(DashboardCardInputSchema.safeParse(card(-0.1)).success).toBe(false);
    expect(DashboardCardInputSchema.safeParse(card(42)).success).toBe(false);
    expect(DashboardCardInputSchema.safeParse(card(0)).success).toBe(true);
    expect(DashboardCardInputSchema.safeParse(card(1)).success).toBe(true);
  });

  it("accepts a deadline on any template and validates it like other dates", () => {
    const card = (deadline: string) => ({
      id: "cert-expiry",
      template: "summary" as const,
      title: "TLS certificate",
      deadline,
    });
    expect(DashboardCardInputSchema.safeParse(card("2026-09-02T00:00:00Z")).success).toBe(true);
    expect(DashboardCardInputSchema.safeParse(card("2026-09-02")).success).toBe(false);
  });

  it("accepts an https deepLink on a row and refuses anything else", () => {
    const withLink = (deepLink: string) => ({
      id: "services",
      template: "list" as const,
      title: "Services",
      items: [{ id: "api", title: "API", deepLink }],
    });
    expect(DashboardCardInputSchema.safeParse(withLink("https://example.com/api")).success).toBe(true);
    // Same policy as a card's own link: no other scheme reaches the device.
    expect(DashboardCardInputSchema.safeParse(withLink("http://example.com")).success).toBe(false);
    expect(DashboardCardInputSchema.safeParse(withLink("javascript:alert(1)")).success).toBe(false);
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

  it("accepts a chart card and defaults its style", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "requests",
      template: "chart",
      title: "Requests",
      value: "412",
      chart: { points: [1, 2, 3, 4, 5, 4, 3, 2, 1, 0] },
    });
    expect(parsed.success).toBe(true);
    if (parsed.success) expect(parsed.data.chart?.style).toBe("line");
  });

  it("rejects chart series outside the published point range", () => {
    const card = (points: number[]) => ({
      id: "a",
      template: "chart" as const,
      title: "x",
      chart: { points },
    });
    expect(DashboardCardSchema.safeParse(card([1])).success).toBe(false);
    expect(
      DashboardCardSchema.safeParse(
        card(Array.from({ length: FieldLimits.chartPointCount + 1 }, (_, i) => i)),
      ).success,
    ).toBe(false);
    expect(
      DashboardCardSchema.safeParse(
        card(Array.from({ length: FieldLimits.chartPointCount }, (_, i) => i)),
      ).success,
    ).toBe(true);
  });

  it("accepts amounts on list items, which rank the rows", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "top-processes",
      template: "list",
      title: "Memory",
      items: [
        { id: "node", title: "node", value: "1.2 GB", amount: 1200 },
        { id: "swift", title: "swift-frontend", value: "740 MB", amount: 740 },
      ],
    });
    expect(parsed.success).toBe(true);
    if (parsed.success) expect(parsed.data.items?.map((i) => i.amount)).toEqual([1200, 740]);
  });

  it("accepts a breakdown card with item amounts", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "disk",
      template: "breakdown",
      title: "Disk",
      items: [
        { id: "media", title: "Media", value: "512 GB", amount: 512 },
        { id: "free", title: "Free", amount: 112, status: "warning" },
      ],
    });
    expect(parsed.success).toBe(true);
    if (parsed.success) expect(parsed.data.items?.[0].amount).toBe(512);
    // amount is numeric, never the display string it sits beside.
    expect(
      DashboardCardSchema.safeParse({
        id: "disk",
        template: "breakdown",
        title: "Disk",
        items: [{ id: "media", title: "Media", amount: "512 GB" }],
      }).success,
    ).toBe(false);
  });

  it("accepts a history card whose items carry statuses", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "ci",
      template: "history",
      title: "CI",
      value: "9/10",
      items: [
        { id: "1", title: "#481", status: "good" },
        { id: "2", title: "#482", status: "critical" },
      ],
    });
    expect(parsed.success).toBe(true);
    if (parsed.success) expect(parsed.data.items?.[1].status).toBe("critical");
    // The pips share the card-wide item cap; nothing about history relaxes it.
    expect(
      DashboardCardSchema.safeParse({
        id: "ci",
        template: "history",
        title: "CI",
        items: Array.from({ length: FieldLimits.itemCount + 1 }, (_, i) => ({
          id: `${i}`,
          title: `#${i}`,
          status: "good",
        })),
      }).success,
    ).toBe(false);
  });

  it("accepts the delta chart style and rejects unknown styles", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "a",
      template: "chart",
      title: "x",
      chart: { points: [-2, 1, 3], style: "delta" },
    });
    expect(parsed.success).toBe(true);
    if (parsed.success) expect(parsed.data.chart?.style).toBe("delta");
    expect(
      DashboardCardSchema.safeParse({
        id: "a",
        template: "chart",
        title: "x",
        chart: { points: [1, 2], style: "candlestick" },
      }).success,
    ).toBe(false);
  });

  it("accepts a chart reference value", () => {
    const parsed = DashboardCardSchema.safeParse({
      id: "a",
      template: "chart",
      title: "x",
      chart: { points: [1, 2, 3], reference: 2.5 },
    });
    expect(parsed.success).toBe(true);
    if (parsed.success) expect(parsed.data.chart?.reference).toBe(2.5);
    expect(
      DashboardCardSchema.safeParse({
        id: "a",
        template: "chart",
        title: "x",
        chart: { points: [1, 2, 3], reference: Number.NaN },
      }).success,
    ).toBe(false);
  });

  it("rejects non-finite chart points and an inverted range", () => {
    expect(
      DashboardCardSchema.safeParse({
        id: "a",
        template: "chart",
        title: "x",
        chart: { points: [1, Number.POSITIVE_INFINITY] },
      }).success,
    ).toBe(false);
    expect(
      DashboardCardSchema.safeParse({
        id: "a",
        template: "chart",
        title: "x",
        chart: { points: [1, 2], min: 10, max: 0 },
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

  it("round-trips a chart series through storage", async () => {
    const env = makeEnv();
    const body = {
      id: "cpu-load",
      template: "chart",
      title: "CPU",
      value: "38",
      unit: "%",
      chart: { points: [12, 18, 22, 41, 37, 29, 33, 45, 40, 38], min: 0, max: 100, style: "bar" },
    };
    const upsert = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", { method: "POST", body: JSON.stringify(body) }),
      env,
      executionCtx,
    );
    expect(upsert.status).toBe(200);

    const read = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/cpu-load", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(read.status).toBe(200);
    const { card } = (await read.json()) as {
      card: { chart?: { points: number[]; min?: number; style: string } };
    };
    expect(card.chart?.points).toEqual(body.chart.points);
    expect(card.chart?.min).toBe(0);
    expect(card.chart?.style).toBe("bar");
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
    const hash = await sha256Hex(TEST_API_KEY);
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
    const hash = await sha256Hex(TEST_API_KEY);

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

describe("card ordering", () => {
  const seed = async (env: ReturnType<typeof makeEnv>, cards: Array<Record<string, unknown>>) => {
    for (const card of cards) {
      const res = await (handler.fetch as any)(
        authedRequest("https://x/v1/cards/upsert", { method: "POST", body: JSON.stringify(card) }),
        env,
        executionCtx,
      );
      expect(res.status).toBe(200);
    }
  };
  const listed = async (env: ReturnType<typeof makeEnv>) => {
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", { method: "GET" }),
      env,
      executionCtx,
    );
    return ((await res.json()) as { cards: Array<{ id: string }> }).cards.map((c) => c.id);
  };

  it("puts higher priority first and breaks ties by id", async () => {
    const env = makeEnv();
    await seed(env, [
      { id: "zebra", template: "summary", title: "Z", priority: 10 },
      { id: "alpha", template: "summary", title: "A" },
      { id: "middle", template: "summary", title: "M", priority: 5 },
      { id: "beta", template: "summary", title: "B" },
      { id: "demoted", template: "summary", title: "D", priority: -1 },
    ]);
    expect(await listed(env)).toEqual(["zebra", "middle", "alpha", "beta", "demoted"]);
  });

  it("keeps the id order for cards that set no priority", async () => {
    // The order everything had before this field existed, so a producer that
    // ignores it sees no change.
    const env = makeEnv();
    await seed(env, [
      { id: "queue-depth", template: "summary", title: "Q" },
      { id: "api-status", template: "summary", title: "A" },
      { id: "database-status", template: "summary", title: "D" },
    ]);
    expect(await listed(env)).toEqual(["api-status", "database-status", "queue-depth"]);
  });

  it("orders the dashboard the same way", async () => {
    const env = makeEnv();
    await seed(env, [
      { id: "alpha", template: "summary", title: "A" },
      { id: "zebra", template: "summary", title: "Z", priority: 3 },
    ]);
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/dashboard", { method: "GET" }),
      env,
      executionCtx,
    );
    const body = (await res.json()) as { cards: Array<{ id: string }> };
    expect(body.cards.map((c) => c.id)).toEqual(["zebra", "alpha"]);
  });
});

describe("documented compatibility promises", () => {
  it("ignores request fields it does not recognise", async () => {
    // So an integration written against a newer deployment does not break when
    // it meets an older one, and nobody has to feature-detect before publishing.
    const parsed = DashboardCardInputSchema.safeParse({
      id: "solar-home",
      template: "summary",
      title: "Solar",
      somethingFromTheFuture: { nested: true },
    });
    expect(parsed.success).toBe(true);
    expect(parsed.success && parsed.data).not.toHaveProperty("somethingFromTheFuture");
  });

  it("degrades an unknown status rather than rejecting the card", () => {
    const parsed = DashboardCardInputSchema.safeParse({
      id: "a",
      template: "summary",
      title: "x",
      status: "brand-new-status",
    });
    expect(parsed.success).toBe(true);
    expect(parsed.success && parsed.data.status).toBe("unknown");
  });
});

describe("documented idempotency", () => {
  // The error list says 404 covers a card id that does not exist, and DELETE
  // deliberately does not follow it. Pinned so the documented promise and the
  // behaviour cannot drift apart.
  it("answers 200 when deleting a card that is not there", async () => {
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/never-existed", { method: "DELETE" }),
      makeEnv(),
      executionCtx,
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });
});

describe("GET /v1/cards/:id", () => {
  it("answers with a { card } envelope, like every other read", async () => {
    const env = makeEnv();
    await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify({ id: "solar-home", template: "summary", title: "Solar" }),
      }),
      env,
      executionCtx,
    );

    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/solar-home", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { card: { id: string; title: string } };
    expect(body.card.id).toBe("solar-home");
    expect(body.card.title).toBe("Solar");
  });

  it("still 404s a card that is not there", async () => {
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/nope", { method: "GET" }),
      makeEnv(),
      executionCtx,
    );
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not found" });
  });
});

describe("path parameter decoding", () => {
  it("reaches a stored card whose id needs percent-encoding", async () => {
    const env = makeEnv();
    // The schema refuses this id now, so write it the way a card stored before
    // that rule exists: straight into storage.
    await storage.putCard(env, "test-tenant", await sha256Hex(TEST_API_KEY), {
      id: "legacy/card",
      template: "summary",
      title: "Legacy",
      status: "unknown",
    });

    const get = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/legacy%2Fcard", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(get.status).toBe(200);

    const del = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/legacy%2Fcard", { method: "DELETE" }),
      env,
      executionCtx,
    );
    expect(del.status).toBe(200);

    expect(await storage.getCard(env, "test-tenant", "legacy/card")).toBeNull();
  });

  it("does not 500 on a malformed escape", async () => {
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/%E0%A4%A", { method: "GET" }),
      makeEnv(),
      executionCtx,
    );
    expect(res.status).toBe(404);
  });
});
