import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { mintChain, signJws, type TestChain } from "./appleCertFixtures";
import { authedRequest, makeEnv, FakeD1 } from "./helpers";
import type { Env } from "../src/types";

// Apple's private key is not available to sign fixtures, so the pinned root is
// swapped for one the tests can mint chains under. Mocking the module rather
// than threading a root through the production call path keeps `verifyTransaction`
// free of test-only parameters — it always trusts exactly one root.
const trustedRoot = vi.hoisted(() => ({ der: new Uint8Array() as Uint8Array }));
vi.mock("../src/appleRootCA", () => ({
  get APPLE_ROOT_CA_G3_DER() {
    return trustedRoot.der;
  },
}));

const handler = (await import("../src/index")).default;

const executionCtx = {} as ExecutionContext;
const BUNDLE_ID = "com.example.zerozerowidget";
const MONTHLY = "com.example.zerozerowidget.pro.monthly";
const YEARLY = "com.example.zerozerowidget.pro.yearly";
const DAY_MS = 24 * 60 * 60 * 1000;

let chain: TestChain;

beforeAll(async () => {
  chain = await mintChain({ caCurve: "P-384" });
  trustedRoot.der = chain.root.der;
});

function subscriptionEnv(overrides: Partial<Env> = {}): Env {
  return makeEnv({
    SUBSCRIPTIONS_ENABLED: "true",
    SUBSCRIPTION_PRODUCT_IDS: `${MONTHLY},${YEARLY}`,
    APNS_BUNDLE_ID: BUNDLE_ID,
    ...overrides,
  });
}

interface TransactionOverrides {
  originalTransactionId?: string;
  productId?: string;
  bundleId?: string;
  environment?: string;
  expiresDate?: number | null;
  revocationDate?: number;
  signedDate?: number;
  offerType?: number;
}

async function signedTransaction(overrides: TransactionOverrides = {}): Promise<string> {
  const payload: Record<string, unknown> = {
    originalTransactionId: overrides.originalTransactionId ?? "original-1",
    productId: overrides.productId ?? MONTHLY,
    bundleId: overrides.bundleId ?? BUNDLE_ID,
    environment: overrides.environment ?? "Production",
    signedDate: overrides.signedDate ?? 1_000,
    type: "Auto-Renewable Subscription",
  };
  if (overrides.expiresDate !== null) {
    payload.expiresDate = overrides.expiresDate ?? Date.now() + 30 * DAY_MS;
  }
  if (overrides.revocationDate !== undefined) payload.revocationDate = overrides.revocationDate;
  if (overrides.offerType !== undefined) payload.offerType = overrides.offerType;
  return signJws(chain, payload);
}

async function verify(env: Env, transactions: string[]): Promise<Response> {
  return (handler.fetch as any)(
    authedRequest("https://api.test/v1/subscription/verify", {
      method: "POST",
      body: JSON.stringify({ signedTransactions: transactions }),
    }),
    env,
    executionCtx,
  );
}

async function notify(env: Env, signedPayload: unknown): Promise<Response> {
  return (handler.fetch as any)(
    new Request("https://api.test/v1/apple/subscription-notifications", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ signedPayload }),
    }),
    env,
    executionCtx,
  );
}

describe("POST /v1/subscription/verify", () => {
  it("records a valid transaction and reports the entitlement", async () => {
    const env = subscriptionEnv();

    const res = await verify(env, [await signedTransaction()]);

    expect(res.status).toBe(200);
    const body = await res.json() as any;
    expect(body.accepted).toBe(1);
    expect(body.subscription.status).toBe("active");
    expect(body.subscription.active).toBe(true);
    expect(body.subscription.productId).toBe(MONTHLY);
  });

  it("reports a free trial as its own status", async () => {
    const env = subscriptionEnv();

    // offerType 1 is an introductory offer, which is how a free trial arrives.
    const res = await verify(env, [await signedTransaction({ offerType: 1 })]);

    const body = await res.json() as any;
    expect(body.subscription.status).toBe("trial");
    expect(body.subscription.active).toBe(true);
  });

  it("rejects a transaction signed under a chain we do not trust", async () => {
    const env = subscriptionEnv();
    const attacker = await mintChain();
    const forged = await signJws(attacker, {
      originalTransactionId: "forged",
      productId: MONTHLY,
      bundleId: BUNDLE_ID,
      environment: "Production",
      expiresDate: Date.now() + 30 * DAY_MS,
    });

    const res = await verify(env, [forged]);

    expect(res.status).toBe(400);
    expect((await res.json() as any).error).toMatch(/trusted root/);
  });

  it("rejects a transaction for another app's bundle id", async () => {
    const env = subscriptionEnv();

    const res = await verify(env, [await signedTransaction({ bundleId: "com.someone.else" })]);

    expect(res.status).toBe(400);
    expect((await res.json() as any).error).toMatch(/different app/);
  });

  it("rejects a product this deployment does not sell", async () => {
    const env = subscriptionEnv();

    const res = await verify(env, [await signedTransaction({ productId: "com.example.other" })]);

    expect(res.status).toBe(400);
    expect((await res.json() as any).error).toMatch(/unrecognised product/);
  });

  it("rejects a sandbox transaction on a production deployment", async () => {
    const env = subscriptionEnv();

    const res = await verify(env, [await signedTransaction({ environment: "Sandbox" })]);

    expect(res.status).toBe(400);
    expect((await res.json() as any).error).toMatch(/Sandbox environment/);
  });

  it("accepts a sandbox transaction where sandbox is what is configured", async () => {
    const env = subscriptionEnv({ SUBSCRIPTION_ENVIRONMENT: "Sandbox" });

    const res = await verify(env, [await signedTransaction({ environment: "Sandbox" })]);

    expect(res.status).toBe(200);
    expect((await res.json() as any).subscription.active).toBe(true);
  });

  it("keeps a usable transaction when another in the batch is not ours", async () => {
    const env = subscriptionEnv();

    // StoreKit hands over every entitlement the account holds, which can
    // legitimately include products from another app or another group.
    const res = await verify(env, [
      await signedTransaction({ productId: "com.example.other", originalTransactionId: "other" }),
      await signedTransaction(),
    ]);

    expect(res.status).toBe(200);
    const body = await res.json() as any;
    expect(body.accepted).toBe(1);
    expect(body.rejected).toHaveLength(1);
    expect(body.subscription.active).toBe(true);
  });

  it("refuses to move a purchase to a second account", async () => {
    const env = subscriptionEnv();
    (env.ZW_DB as unknown as FakeD1).seedSubscription({
      originalTransactionId: "original-1",
      tenantId: "somebody-else",
    });

    const res = await verify(env, [await signedTransaction({ originalTransactionId: "original-1" })]);

    expect(res.status).toBe(400);
    expect((await res.json() as any).error).toMatch(/already linked to another account/);
  });

  it("404s when subscriptions are not enabled", async () => {
    const env = makeEnv();

    const res = await verify(env, [await signedTransaction()]);

    expect(res.status).toBe(404);
  });

  it("rejects a body that is not a list of JWS strings", async () => {
    const env = subscriptionEnv();

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription/verify", {
        method: "POST",
        body: JSON.stringify({ signedTransactions: [{ nope: true }] }),
      }),
      env,
      executionCtx,
    );

    expect(res.status).toBe(400);
  });
});

describe("GET /v1/subscription", () => {
  it("reports no subscription for a tenant that has never paid", async () => {
    const env = subscriptionEnv();

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );

    expect(res.status).toBe(200);
    const body = await res.json() as any;
    expect(body.subscription.status).toBe("none");
    expect(body.required).toBe(false);
    expect(body.productIds).toEqual([MONTHLY, YEARLY]);
  });

  it("tells the app when writes are gated, which it cannot otherwise know", async () => {
    const env = subscriptionEnv({ SUBSCRIPTION_REQUIRED: "true" });

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );

    expect((await res.json() as any).required).toBe(true);
  });

  it("404s when subscriptions are not enabled", async () => {
    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      makeEnv(),
      executionCtx,
    );

    expect(res.status).toBe(404);
  });
});

describe("POST /v1/apple/subscription-notifications", () => {
  async function signedNotification(input: {
    notificationType: string;
    transaction?: TransactionOverrides;
    renewalInfo?: Record<string, unknown>;
  }): Promise<string> {
    const data: Record<string, unknown> = {
      signedTransactionInfo: await signedTransaction(input.transaction ?? {}),
    };
    if (input.renewalInfo) {
      data.signedRenewalInfo = await signJws(chain, input.renewalInfo);
    }
    return signJws(chain, { notificationType: input.notificationType, data });
  }

  it("applies a renewal for a purchase the app has already claimed", async () => {
    const env = subscriptionEnv();
    await verify(env, [await signedTransaction({ signedDate: 1_000 })]);
    const renewedTo = Date.now() + 60 * DAY_MS;

    const res = await notify(env, await signedNotification({
      notificationType: "DID_RENEW",
      transaction: { expiresDate: renewedTo, signedDate: 2_000 },
    }));

    expect(res.status).toBe(200);
    expect((await res.json() as any).applied).toBe(true);
    const after = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );
    const body = await after.json() as any;
    expect(body.subscription.active).toBe(true);
    expect(Date.parse(body.subscription.expiresAt)).toBe(renewedTo);
  });

  it("stores a notification for a purchase nobody has claimed yet", async () => {
    const env = subscriptionEnv();

    // The purchase happened but the app never got to verify it — killed,
    // offline, reinstalled. The row has to survive until it can be adopted.
    const res = await notify(env, await signedNotification({
      notificationType: "SUBSCRIBED",
      transaction: { originalTransactionId: "orphan-1" },
    }));

    expect((await res.json() as any).applied).toBe(true);
    // Nothing is entitled yet, because no tenant owns the row.
    const before = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );
    expect((await before.json() as any).subscription.status).toBe("none");

    // The app checks in later and adopts it.
    await verify(env, [await signedTransaction({ originalTransactionId: "orphan-1", signedDate: 2_000 })]);

    const after = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );
    expect((await after.json() as any).subscription.active).toBe(true);
  });

  it("does not orphan a claimed row when a later notification arrives", async () => {
    const env = subscriptionEnv();
    await verify(env, [await signedTransaction({ signedDate: 1_000 })]);

    await notify(env, await signedNotification({
      notificationType: "DID_RENEW",
      transaction: { signedDate: 2_000 },
    }));

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );
    expect((await res.json() as any).subscription.active).toBe(true);
  });

  it("ignores a notification older than what is already stored", async () => {
    const env = subscriptionEnv();
    const renewedTo = Date.now() + 60 * DAY_MS;
    await verify(env, [await signedTransaction({ expiresDate: renewedTo, signedDate: 5_000 })]);

    // Apple does not guarantee ordering, so a stale EXPIRED can land after the
    // DID_RENEW that superseded it.
    await notify(env, await signedNotification({
      notificationType: "EXPIRED",
      transaction: { expiresDate: Date.now() - DAY_MS, signedDate: 1_000 },
    }));

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );
    const body = await res.json() as any;
    expect(body.subscription.active).toBe(true);
    expect(Date.parse(body.subscription.expiresAt)).toBe(renewedTo);
  });

  it("records a refund as revoked, whatever the expiry still says", async () => {
    const env = subscriptionEnv();
    await verify(env, [await signedTransaction({ signedDate: 1_000 })]);

    await notify(env, await signedNotification({
      notificationType: "REFUND",
      transaction: { revocationDate: Date.now() - 1_000, signedDate: 2_000 },
    }));

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );
    const body = await res.json() as any;
    expect(body.subscription.status).toBe("revoked");
    expect(body.subscription.active).toBe(false);
  });

  it("honours Apple's billing grace period from renewal info", async () => {
    const env = subscriptionEnv({ SUBSCRIPTION_GRACE_DAYS: "0" });
    await verify(env, [await signedTransaction({ signedDate: 1_000 })]);

    await notify(env, await signedNotification({
      notificationType: "DID_FAIL_TO_RENEW",
      transaction: { expiresDate: Date.now() - DAY_MS, signedDate: 2_000 },
      renewalInfo: { autoRenewStatus: 1, gracePeriodExpiresDate: Date.now() + 5 * DAY_MS },
    }));

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );
    const body = await res.json() as any;
    expect(body.subscription.status).toBe("grace");
    expect(body.subscription.active).toBe(true);
  });

  it("rejects a notification that is not signed by the trusted chain", async () => {
    const env = subscriptionEnv();
    const attacker = await mintChain();
    const forged = await signJws(attacker, { notificationType: "DID_RENEW", data: {} });

    const res = await notify(env, forged);

    expect(res.status).toBe(401);
  });

  it("acknowledges a notification carrying no transaction", async () => {
    const env = subscriptionEnv();
    const payload = await signJws(chain, { notificationType: "CONSUMPTION_REQUEST", data: {} });

    const res = await notify(env, payload);

    // 200, not an error: a non-2xx makes Apple retry something we will never
    // act on.
    expect(res.status).toBe(200);
    expect((await res.json() as any).applied).toBe(false);
  });

  it("acknowledges a verified notification for another app rather than retrying forever", async () => {
    const env = subscriptionEnv();

    const res = await notify(env, await signedNotification({
      notificationType: "DID_RENEW",
      transaction: { bundleId: "com.someone.else" },
    }));

    expect(res.status).toBe(200);
    expect((await res.json() as any).applied).toBe(false);
  });

  it("404s when subscriptions are not enabled", async () => {
    const res = await notify(makeEnv(), await signedNotification({ notificationType: "DID_RENEW" }));

    expect(res.status).toBe(404);
  });

  it("requires no credential, because Apple presents none", async () => {
    const env = subscriptionEnv();

    const res = await notify(env, await signedNotification({ notificationType: "DID_RENEW" }));

    // The request above carries no Authorization header at all.
    expect(res.status).toBe(200);
  });
});

describe("entitlement expiry", () => {
  let env: Env;
  let db: FakeD1;

  beforeEach(() => {
    env = subscriptionEnv({ SUBSCRIPTION_GRACE_DAYS: "3" });
    db = env.ZW_DB as unknown as FakeD1;
  });

  async function status(): Promise<any> {
    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );
    return (await res.json() as any).subscription;
  }

  it("keeps a lapsed entitlement active through the configured grace window", async () => {
    db.seedSubscription({ expiresAtMs: Date.now() - DAY_MS });

    const state = await status();

    expect(state.status).toBe("grace");
    expect(state.active).toBe(true);
  });

  it("expires once the grace window has passed", async () => {
    db.seedSubscription({ expiresAtMs: Date.now() - 10 * DAY_MS });

    const state = await status();

    expect(state.status).toBe("expired");
    expect(state.active).toBe(false);
  });

  it("prefers whichever of the two grace windows reaches further", async () => {
    db.seedSubscription({
      expiresAtMs: Date.now() - 10 * DAY_MS,
      graceExpiresAtMs: Date.now() + DAY_MS,
    });

    expect((await status()).status).toBe("grace");
  });

  it("picks the row reaching furthest into the future when a tenant has several", async () => {
    // Resubscribing after a lapse mints a new originalTransactionId, leaving
    // the old row in place.
    db.seedSubscription({ originalTransactionId: "old", expiresAtMs: Date.now() - 90 * DAY_MS });
    db.seedSubscription({ originalTransactionId: "new", expiresAtMs: Date.now() + 30 * DAY_MS });

    expect((await status()).active).toBe(true);
  });

  it("ignores a subscription belonging to another tenant", async () => {
    db.seedSubscription({ tenantId: "somebody-else" });

    expect((await status()).status).toBe("none");
  });
});
