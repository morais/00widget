import { afterEach, describe, expect, it, vi } from "vitest";
import { authedRequest, FakeD1, makeEnv, seedApiKey, TEST_API_KEY } from "./helpers";
import type { Env } from "../src/types";

const handler = (await import("../src/index")).default;
const ctx = {} as ExecutionContext;
const SKU = "com.example.zerozerowidget.subscription";

function metaEnv(overrides: Partial<Env> = {}): Env {
  return makeEnv({
    SUBSCRIPTIONS_ENABLED: "true",
    META_SUBSCRIPTIONS_ENABLED: "true",
    META_SUBSCRIPTION_SKU: SKU,
    META_APP_ID: "meta-app-123",
    META_APP_SECRET: "meta-secret",
    ...overrides,
  });
}

function graphRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "meta-subscription-1",
    sku: SKU,
    owner: { id: "meta-owner-1" },
    is_active: true,
    is_trial: false,
    period_start_time: "2026-09-01T00:00:00+0000",
    period_end_time: "2026-10-01T00:00:00+0000",
    next_renewal_time: "2026-10-01T00:00:00+0000",
    current_price_term: { term: "MONTHLY", currency: "USD", price: "2.99" },
    next_price_term: { term: "MONTHLY", currency: "USD", price: "2.99" },
    ...overrides,
  };
}

async function sync(env: Env, token = "OC-user-token", apiKey = TEST_API_KEY): Promise<Response> {
  return (handler.fetch as any)(
    authedRequest("https://api.test/v1/meta/subscription/sync", {
      method: "POST",
      body: JSON.stringify({ userAccessToken: token }),
    }, apiKey),
    env,
    ctx,
  );
}

afterEach(() => vi.unstubAllGlobals());

describe("POST /v1/meta/subscription/sync", () => {
  it("verifies the user with Meta app credentials and claims the entitlement", async () => {
    const env = metaEnv();
    const calls: URL[] = [];
    vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input));
      calls.push(url);
      return Response.json({ data: [graphRow()] });
    }));

    const res = await sync(env);

    expect(res.status).toBe(200);
    expect((await res.json() as any)).toMatchObject({
      synced: 1,
      subscription: {
        status: "active",
        active: true,
        provider: "meta",
        productId: SKU,
      },
    });
    expect(calls).toHaveLength(2);
    expect(calls[0].searchParams.get("access_token")).toBe("OC-user-token");
    expect(calls[0].searchParams.has("owner_id")).toBe(false);
    expect(calls[1].searchParams.get("access_token")).toBe("OC|meta-app-123|meta-secret");
    expect(calls[1].searchParams.get("owner_id")).toBe("meta-owner-1");
    expect(calls[1].searchParams.get("skus")).toBe(SKU);
  });

  it("does not grant access when our Meta app has no matching subscription", async () => {
    const env = metaEnv();
    let call = 0;
    vi.stubGlobal("fetch", vi.fn(async () => {
      call++;
      return Response.json({ data: call === 1 ? [graphRow()] : [] });
    }));

    const res = await sync(env);
    const body = await res.json() as any;

    expect(res.status).toBe(200);
    expect(body.synced).toBe(0);
    expect(body.subscription.status).toBe("none");
  });

  it("refuses to attach one Meta owner to a second 00Widget tenant", async () => {
    const env = metaEnv();
    await seedApiKey(env, "tenant-b-key", "tenant-b");
    (env.ZW_DB as unknown as FakeD1).seedMetaSubscription({
      ownerId: "meta-owner-1",
      tenantId: "test-tenant",
      sku: SKU,
    });
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ data: [graphRow()] })));

    const res = await sync(env, "OC-user-token", "tenant-b-key");

    expect(res.status).toBe(400);
    expect((await res.json() as any).error).toMatch(/already linked/);
  });

  it("does not expose Meta's response or the supplied token on verification failure", async () => {
    const env = metaEnv();
    vi.stubGlobal("fetch", vi.fn(async () => Response.json(
      { error: { message: "token OC-user-secret-token is invalid" } },
      { status: 401 },
    )));

    const res = await sync(env, "OC-user-secret-token");
    const body = await res.json() as any;

    expect(res.status).toBe(400);
    expect(body.error).toBe("Meta could not verify this account");
    expect(JSON.stringify(body)).not.toContain("OC-user-secret-token");
  });

  it("404s until Meta subscriptions are explicitly enabled", async () => {
    const res = await sync(metaEnv({ META_SUBSCRIPTIONS_ENABLED: "false" }));
    expect(res.status).toBe(404);
  });

  it("fails closed when app credentials are missing", async () => {
    const res = await sync(metaEnv({ META_APP_SECRET: undefined }));
    expect(res.status).toBe(503);
  });
});
