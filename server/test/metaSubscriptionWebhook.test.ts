import { describe, expect, it } from "vitest";
import { claimMetaOwnerForTenant } from "../src/metaSubscription";
import type { Env } from "../src/types";
import { authedRequest, makeEnv } from "./helpers";

const handler = (await import("../src/index")).default;
const ctx = {} as ExecutionContext;
const SKU = "com.example.zerozerowidget.subscription";
const SECRET = "meta-app-secret";

function metaEnv(overrides: Partial<Env> = {}): Env {
  return makeEnv({
    SUBSCRIPTIONS_ENABLED: "true",
    META_SUBSCRIPTIONS_ENABLED: "true",
    META_SUBSCRIPTION_SKU: SKU,
    META_APP_ID: "meta-app-123",
    META_APP_SECRET: SECRET,
    META_WEBHOOK_VERIFY_TOKEN: "verify-me",
    ...overrides,
  });
}

function subscription(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "meta-subscription-1",
    sku: SKU,
    is_active: true,
    is_trial: false,
    period_start_time: "1770000000",
    period_end_time: "1772592000",
    next_renewal_time: "1772592000",
    current_price_term: { term: "MONTHLY", currency: "USD", price: "2.99" },
    next_price_term: { term: "MONTHLY", currency: "USD", price: "2.99" },
    ...overrides,
  };
}

function webhookBody(
  field: string,
  subscriptionOverrides: Record<string, unknown> = {},
  time = 1_770_000_000,
): Record<string, unknown> {
  return {
    object: "application",
    entry: [{
      id: "meta-app-123",
      time,
      changes: [{
        field,
        value: {
          owner_id: "meta-owner-1",
          subscription: subscription(subscriptionOverrides),
        },
      }],
    }],
  };
}

async function signature(body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const bytes = new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(body),
  ));
  return `sha256=${[...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

async function notify(env: Env, payload: unknown, signed = true): Promise<Response> {
  const body = JSON.stringify(payload);
  return (handler.fetch as any)(
    new Request("https://api.test/v1/meta/subscription-webhooks", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-hub-signature-256": signed ? await signature(body) : "sha256=wrong",
      },
      body,
    }),
    env,
    ctx,
  );
}

async function state(env: Env): Promise<any> {
  const response = await (handler.fetch as any)(
    authedRequest("https://api.test/v1/subscription"),
    env,
    ctx,
  );
  return (await response.json() as any).subscription;
}

describe("Meta subscription webhooks", () => {
  it("answers Meta's callback verification challenge", async () => {
    const env = metaEnv();
    const ok = await (handler.fetch as any)(
      new Request("https://api.test/v1/meta/subscription-webhooks?hub.mode=subscribe&hub.verify_token=verify-me&hub.challenge=challenge-123"),
      env,
      ctx,
    );
    expect(ok.status).toBe(200);
    expect(await ok.text()).toBe("challenge-123");

    const denied = await (handler.fetch as any)(
      new Request("https://api.test/v1/meta/subscription-webhooks?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=nope"),
      env,
      ctx,
    );
    expect(denied.status).toBe(403);
  });

  it("rejects a notification without a valid app-secret signature", async () => {
    const response = await notify(metaEnv(), webhookBody("subscription_started"), false);
    expect(response.status).toBe(401);
  });

  it("records an unclaimed start and grants it after identity linking", async () => {
    const env = metaEnv();

    const response = await notify(env, webhookBody("subscription_started"));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ applied: 1, ignored: 0 });
    expect((await state(env)).status).toBe("none");

    await claimMetaOwnerForTenant(env, "meta-owner-1", "test-tenant");
    expect(await state(env)).toMatchObject({
      status: "active",
      active: true,
      provider: "meta",
    });
  });

  it("keeps cancellation active through period end and clears auto-renew", async () => {
    const env = metaEnv();
    await notify(env, webhookBody("subscription_started"));
    await claimMetaOwnerForTenant(env, "meta-owner-1", "test-tenant");

    await notify(env, webhookBody("subscription_canceled", {}, 1_770_000_100));

    expect(await state(env)).toMatchObject({ active: true, autoRenew: false });
  });

  it("reactivates a canceled subscription", async () => {
    const env = metaEnv();
    await notify(env, webhookBody("subscription_canceled"));
    await claimMetaOwnerForTenant(env, "meta-owner-1", "test-tenant");

    await notify(env, webhookBody("subscription_uncanceled", {}, 1_770_000_100));

    expect(await state(env)).toMatchObject({ active: true, autoRenew: true });
  });

  it("expires access and ignores a delayed older renewal", async () => {
    const env = metaEnv();
    await notify(env, webhookBody("subscription_started"));
    await claimMetaOwnerForTenant(env, "meta-owner-1", "test-tenant");
    await notify(env, webhookBody("subscription_expired", {}, 1_770_000_200));

    expect(await state(env)).toMatchObject({ status: "expired", active: false });

    await notify(env, webhookBody("subscription_renewal_success", {}, 1_770_000_100));
    expect(await state(env)).toMatchObject({ status: "expired", active: false });
  });

  it("handles batched changes and acknowledges unrelated webhook fields", async () => {
    const env = metaEnv();
    const payload = webhookBody("subscription_started") as any;
    payload.entry[0].changes.push({ field: "join_intent", value: {} });

    const response = await notify(env, payload);

    expect(await response.json()).toMatchObject({ applied: 1, ignored: 1 });
  });
});
