import { afterEach, describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import { authedRequest, makeEnv, seedApiKey } from "./helpers";
import * as storage from "../src/storage";

const executionCtx = {} as ExecutionContext;
type ActionInput = {
  id: string;
  label: string;
  role?: "normal" | "destructive";
  confirm?: boolean;
  payload?: Record<string, string>;
};

describe("webhook integrations and actions", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("registers, reads, rotates, and deletes a webhook integration", async () => {
    const env = makeEnv();

    const created = await (handler.fetch as any)(
      authedRequest("https://x/v1/integrations/webhook", {
        method: "PUT",
        body: JSON.stringify({ url: "https://example.com/actions" }),
      }),
      env,
      executionCtx,
    );
    expect(created.status).toBe(200);
    const createdBody = (await created.json()) as { url: string; signingSecret: string };
    expect(createdBody.url).toBe("https://example.com/actions");
    expect(createdBody.signingSecret).toMatch(/^[0-9a-f]{64}$/);

    const read = await (handler.fetch as any)(
      authedRequest("https://x/v1/integrations/webhook", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(read.status).toBe(200);
    expect(await read.json()).not.toHaveProperty("signingSecret");

    const metadataUpdate = await (handler.fetch as any)(
      authedRequest("https://x/v1/integrations/webhook", {
        method: "PUT",
        body: JSON.stringify({ url: "https://example.com/actions-v2" }),
      }),
      env,
      executionCtx,
    );
    expect(metadataUpdate.status).toBe(200);
    const metadataUpdateBody = await metadataUpdate.json();
    expect(metadataUpdateBody).toMatchObject({
      url: "https://example.com/actions-v2",
      secretCreated: false,
    });
    expect(metadataUpdateBody).not.toHaveProperty("signingSecret");
    expect((await storage.getWebhookIntegration(env, "test-tenant"))?.signingSecret)
      .toBe(createdBody.signingSecret);

    const rotated = await (handler.fetch as any)(
      authedRequest("https://x/v1/integrations/webhook", {
        method: "PUT",
        body: JSON.stringify({ url: "https://example.com/actions", rotateSecret: true }),
      }),
      env,
      executionCtx,
    );
    const rotatedBody = (await rotated.json()) as { signingSecret: string };
    expect(rotatedBody.signingSecret).not.toBe(createdBody.signingSecret);

    const deleted = await (handler.fetch as any)(
      authedRequest("https://x/v1/integrations/webhook", { method: "DELETE" }),
      env,
      executionCtx,
    );
    expect(deleted.status).toBe(200);

    const readDeleted = await (handler.fetch as any)(
      authedRequest("https://x/v1/integrations/webhook", { method: "GET" }),
      env,
      executionCtx,
    );
    expect(readDeleted.status).toBe(404);
  });

  it("rejects webhook integrations for non-public or non-https URLs", async () => {
    const env = makeEnv();
    for (const url of [
      "http://example.com/actions",
      "https://localhost/actions",
      "https://127.0.0.1/actions",
      "https://10.0.0.1/actions",
      "https://172.16.0.1/actions",
      "https://192.168.0.1/actions",
      "https://169.254.169.254/actions",
      "https://[::1]/actions",
      "https://[0:0:0:0:0:0:0:1]/actions",
      "https://[::]/actions",
      "https://[fd00::1]/actions",
      "https://[fc00::1]/actions",
      "https://[fe80::1]/actions",
      "https://example.local/actions",
      // Legacy IPv4 spellings the URL parser canonicalizes to 127.0.0.1.
      "https://2130706433/actions",
      "https://0x7f000001/actions",
      "https://127.1/actions",
      // IPv6 forms that embed a private IPv4 destination.
      "https://[::ffff:127.0.0.1]/actions",
      "https://[::ffff:169.254.169.254]/actions",
      "https://[::ffff:10.0.0.1]/actions",
      "https://[::127.0.0.1]/actions",
      "https://[64:ff9b::127.0.0.1]/actions",
    ]) {
      const res = await (handler.fetch as any)(
        authedRequest("https://x/v1/integrations/webhook", {
          method: "PUT",
          body: JSON.stringify({ url }),
        }),
        env,
        executionCtx,
      );
      expect(res.status, url).toBe(400);
    }
  });

  it("accepts webhook integrations on public hosts, including public IPv6", async () => {
    for (const url of [
      "https://hooks.example.com/actions",
      "https://8.8.8.8/actions",
      "https://[2606:4700:4700::1111]/actions",
      "https://[::ffff:8.8.8.8]/actions",
      "https://[fe00::1]/actions",
    ]) {
      const env = makeEnv();
      const res = await (handler.fetch as any)(
        authedRequest("https://x/v1/integrations/webhook", {
          method: "PUT",
          body: JSON.stringify({ url }),
        }),
        env,
        executionCtx,
      );
      expect(res.status, url).toBe(200);
    }
  });

  it("sends signed action payloads to the configured webhook", async () => {
    const env = makeEnv();
    const registered = await registerWebhook(env);
    await upsertActionCard(env);

    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      const rawBody = String(init.body);
      const body = JSON.parse(rawBody) as {
        deliveryId: string;
        source: string;
        accountId: string;
        action: { id: string; payload: Record<string, string> };
        context: { cardId: string };
      };
      expect(body.source).toBe("widget");
      expect(body.accountId).toBe("test-tenant");
      expect(body.action).toMatchObject({
        id: "boiler-boost-1h",
        payload: { duration: "3600" },
      });
      expect(body.context.cardId).toBe("boiler");
      expect(headers.get("x-00widget-delivery")).toBe(body.deliveryId);
      expect(headers.get("x-00widget-signature")).toBe(
        `sha256=${await hmac(registered.signingSecret, headers.get("x-00widget-timestamp")!, rawBody)}`,
      );
      return new Response(null, { status: 204 });
    });
    vi.stubGlobal("fetch", fetchMock);

    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/boiler-boost-1h/run", {
        method: "POST",
        body: JSON.stringify({ source: "widget", context: { cardId: "boiler" } }),
      }),
      env,
      executionCtx,
    );

    expect(res.status).toBe(200);
    expect((await res.json()) as { ok: boolean; webhookStatus: number }).toMatchObject({
      ok: true,
      webhookStatus: 204,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does not follow webhook redirects", async () => {
    const env = makeEnv();
    await registerWebhook(env);
    await upsertActionCard(env);
    const fetchMock = vi.fn(async (_url: string, init: RequestInit) => {
      expect(init.redirect).toBe("manual");
      return new Response(null, {
        status: 302,
        headers: { location: "https://127.0.0.1/actions" },
      });
    });
    vi.stubGlobal("fetch", fetchMock);

    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/boiler-boost-1h/run", {
        method: "POST",
        body: JSON.stringify({ source: "widget", context: { cardId: "boiler" } }),
      }),
      env,
      executionCtx,
    );

    expect(res.status).toBe(502);
    expect((await res.json()) as { status: number }).toMatchObject({ status: 302 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("rejects widget action runs without card context", async () => {
    const env = makeEnv();
    await registerWebhook(env);
    await upsertActionCard(env);

    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/boiler-boost-1h/run", {
        method: "POST",
        body: JSON.stringify({ source: "widget" }),
      }),
      env,
      executionCtx,
    );

    expect(res.status).toBe(403);
    expect(await res.json()).toMatchObject({ error: "widget actions require card context" });
  });

  it("rejects destructive or confirming actions from widgets", async () => {
    const env = makeEnv();
    await registerWebhook(env);
    await upsertActionCard(env, [
      {
        id: "boiler-reset",
        label: "Reset",
        role: "destructive",
      },
      {
        id: "boiler-confirm",
        label: "Confirm",
        confirm: true,
      },
    ]);

    for (const actionId of ["boiler-reset", "boiler-confirm"]) {
      const res = await (handler.fetch as any)(
        authedRequest(`https://x/v1/actions/${actionId}/run`, {
          method: "POST",
          body: JSON.stringify({ source: "widget", context: { cardId: "boiler" } }),
        }),
        env,
        executionCtx,
      );
      expect(res.status, actionId).toBe(403);
      expect(await res.json()).toMatchObject({ error: "action is not safe to run from widgets" });
    }
  });

  it("allows destructive actions only through an app-scoped confirmation path", async () => {
    const env = makeEnv();
    await seedApiKey(env, "app-key", "test-tenant", "app");
    await registerWebhook(env);
    await upsertActionCard(env, [
      {
        id: "boiler-reset",
        label: "Reset",
        role: "destructive",
      },
    ]);
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 204 })));

    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/boiler-reset/run-confirmed", {
        method: "POST",
        body: JSON.stringify({ context: { cardId: "boiler" } }),
      }, "app-key"),
      env,
      executionCtx,
    );

    expect(res.status).toBe(200);
  });

  it("does not trust a caller-supplied source on the publisher endpoint", async () => {
    const env = makeEnv();
    await registerWebhook(env);
    await upsertActionCard(env, [{ id: "boiler-reset", label: "Reset", role: "destructive" }]);

    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/boiler-reset/run", {
        method: "POST",
        body: JSON.stringify({ source: "app", context: { cardId: "boiler" } }),
      }),
      env,
      executionCtx,
    );

    expect(res.status).toBe(403);
    expect(await res.json()).toMatchObject({ error: "action is not safe to run from widgets" });
  });

  it("rejects publisher credentials on the confirmed action endpoint", async () => {
    const env = makeEnv();
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/anything/run-confirmed", {
        method: "POST",
        body: JSON.stringify({ context: { cardId: "boiler" } }),
      }),
      env,
      executionCtx,
    );
    expect(res.status).toBe(403);
    expect(await res.json()).toMatchObject({ error: "app credential required" });
  });

  it("upserts a response card returned by the webhook", async () => {
    const env = makeEnv();
    await registerWebhook(env);
    await upsertActionCard(env);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        Response.json({
          card: {
            id: "boiler",
            template: "action",
            title: "Boiler",
            value: "Boosting",
            status: "running",
            actions: [{ id: "boiler-boost-1h", label: "Boost 1h", payload: { duration: "3600" } }],
          },
        }),
      ),
    );

    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/boiler-boost-1h/run", {
        method: "POST",
        body: JSON.stringify({ context: { cardId: "boiler" } }),
      }),
      env,
      executionCtx,
    );
    expect(res.status).toBe(200);
    expect((await res.json()) as { updatedCard: boolean }).toMatchObject({ updatedCard: true });

    const card = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards/boiler", { method: "GET" }),
      env,
      executionCtx,
    );
    const cardBody = (await card.json()) as {
      card: { value: string; actions: Array<Record<string, unknown>> };
    };
    expect(cardBody.card.value).toBe("Boosting");
    expect(cardBody.card.actions[0]).not.toHaveProperty("payload");
    await expect(
      storage.getActionPayload(
        env,
        "test-tenant",
        "boiler",
        "boiler-boost-1h",
      ),
    ).resolves.toEqual({ duration: "3600" });
  });

  it("ignores oversized webhook response bodies", async () => {
    const env = makeEnv();
    await registerWebhook(env);
    await upsertActionCard(env);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ card: "x".repeat(70 * 1024) }))),
    );

    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/boiler-boost-1h/run", {
        method: "POST",
        body: JSON.stringify({ context: { cardId: "boiler" } }),
      }),
      env,
      executionCtx,
    );
    expect(res.status).toBe(200);
    expect((await res.json()) as { updatedCard: boolean }).toMatchObject({ updatedCard: false });
  });

  it("fails action runs when no webhook is configured", async () => {
    const env = makeEnv();
    const res = await (handler.fetch as any)(
      authedRequest("https://x/v1/actions/boiler-boost-1h/run", {
        method: "POST",
        body: JSON.stringify({ context: { cardId: "boiler" } }),
      }),
      env,
      executionCtx,
    );
    expect(res.status).toBe(409);
  });
});

async function registerWebhook(env: ReturnType<typeof makeEnv>): Promise<{ signingSecret: string }> {
  const res = await (handler.fetch as any)(
    authedRequest("https://x/v1/integrations/webhook", {
      method: "PUT",
      body: JSON.stringify({ url: "https://example.com/actions" }),
    }),
    env,
    executionCtx,
  );
  return (await res.json()) as { signingSecret: string };
}

async function upsertActionCard(
  env: ReturnType<typeof makeEnv>,
  actions: ActionInput[] = [
    {
      id: "boiler-boost-1h",
      label: "Boost 1h",
      payload: { duration: "3600" },
    },
  ],
): Promise<void> {
  const res = await (handler.fetch as any)(
    authedRequest("https://x/v1/cards/upsert", {
      method: "POST",
      body: JSON.stringify({
        id: "boiler",
        template: "action",
        title: "Boiler",
        value: "Ready",
        actions,
      }),
    }),
    env,
    executionCtx,
  );
  expect(res.status).toBe(200);
}

async function hmac(secret: string, timestamp: string, rawBody: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${timestamp}.${rawBody}`),
  );
  return [...new Uint8Array(sig)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
