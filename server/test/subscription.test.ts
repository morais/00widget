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
const MONTHLY = "com.example.zerozerowidget.monthly";
const YEARLY = "com.example.zerozerowidget.yearly";
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

  it("rejects every transaction when there is no bundle id to check against", async () => {
    // The check used to read `if (expected && mismatch)`, so an unset bundle
    // id did not fail it, it removed it — and every transaction on the App
    // Store verified. Subscriptions and APNs are configured independently, so
    // this is a state a real deployment can be in.
    const env = subscriptionEnv({ APNS_BUNDLE_ID: undefined });

    const res = await verify(env, [await signedTransaction({ bundleId: "com.someone.else" })]);

    expect(res.status).toBe(400);
    const error = (await res.json() as any).error as string;
    expect(error).toMatch(/cannot verify transactions/);
    // Which variable is unset goes to the log, not to the caller.
    expect(error).not.toMatch(/APNS_BUNDLE_ID/);
  });

  it("rejects our own app's transaction too when the bundle id is unset", async () => {
    // Failing closed means closed: it does not quietly keep working for the
    // transactions that would have passed anyway.
    const env = subscriptionEnv({ APNS_BUNDLE_ID: undefined });

    const res = await verify(env, [await signedTransaction({})]);

    expect(res.status).toBe(400);
    expect((await res.json() as any).error).toMatch(/cannot verify transactions/);
  });

  it("rejects a product this deployment does not sell", async () => {
    const env = subscriptionEnv();

    const res = await verify(env, [await signedTransaction({ productId: "com.example.other" })]);

    expect(res.status).toBe(400);
    expect((await res.json() as any).error).toMatch(/unrecognised product/);
  });

  it("accepts any of our own products when none are listed", async () => {
    // Deliberately permissive, unlike the bundle id: the transaction is
    // already known to be for this app, and a deployment selling one product
    // that never listed it should not be stranded.
    const env = subscriptionEnv({ SUBSCRIPTION_PRODUCT_IDS: undefined });

    const res = await verify(env, [await signedTransaction({ productId: "com.example.other" })]);

    expect(res.status).toBe(200);
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

  it("accepts both production and sandbox transactions with the explicit sandbox opt-in", async () => {
    const env = subscriptionEnv({ SUBSCRIPTION_SANDBOX_ENABLED: "true" });

    const production = await verify(env, [await signedTransaction({
      originalTransactionId: "production-original",
      environment: "Production",
    })]);
    const sandbox = await verify(env, [await signedTransaction({
      originalTransactionId: "sandbox-original",
      environment: "Sandbox",
      expiresDate: Date.now() + 60 * DAY_MS,
    })]);

    expect(production.status).toBe(200);
    expect(sandbox.status).toBe(200);
    const body = await sandbox.json() as any;
    expect(body.subscription.active).toBe(true);
    expect(body.subscription.environment).toBe("Sandbox");
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
    expect(body.acceptedEnvironments).toEqual(["Production"]);
  });

  it("reports both accepted environments when sandbox testing is enabled", async () => {
    const env = subscriptionEnv({ SUBSCRIPTION_SANDBOX_ENABLED: "true" });

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/v1/subscription"),
      env,
      executionCtx,
    );

    expect((await res.json() as any).acceptedEnvironments)
      .toEqual(["Production", "Sandbox"]);
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
      // Apple's JWSRenewalInfoDecodedPayload names the transaction it is about.
      // Defaulted here so a test says only what it is varying; a test that is
      // *about* the identity overrides it.
      data.signedRenewalInfo = await signJws(chain, {
        originalTransactionId:
          input.transaction?.originalTransactionId ?? "original-1",
        ...input.renewalInfo,
      });
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

  it("accepts sandbox notifications when sandbox testing is enabled", async () => {
    const env = subscriptionEnv({ SUBSCRIPTION_SANDBOX_ENABLED: "true" });

    const res = await notify(env, await signedNotification({
      notificationType: "SUBSCRIBED",
      transaction: { originalTransactionId: "sandbox-notification", environment: "Sandbox" },
    }));

    expect(res.status).toBe(200);
    expect((await res.json() as any).applied).toBe(true);
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

  // The two halves of a notification arrive in one body that anyone can
  // compose — the endpoint is unauthenticated by necessity. A signature proves
  // Apple signed each half, never that they are halves of the same thing.
  describe("renewal info is bound to the transaction it arrives with", () => {
    async function statusAfter(env: any): Promise<any> {
      const res = await (handler.fetch as any)(
        authedRequest("https://api.test/v1/subscription"),
        env,
        executionCtx,
      );
      return (await res.json() as any).subscription;
    }

    it("ignores a grace period signed for another transaction", async () => {
      const env = subscriptionEnv({ SUBSCRIPTION_GRACE_DAYS: "0" });
      await verify(env, [await signedTransaction({ signedDate: 1_000 })]);

      // A real expired transaction, paired with renewal info Apple genuinely
      // signed for a subscription the attacker owns. Before this was checked,
      // its distant grace date held the victim's entitlement open.
      await notify(env, await signedNotification({
        notificationType: "DID_FAIL_TO_RENEW",
        transaction: { expiresDate: Date.now() - DAY_MS, signedDate: 2_000 },
        renewalInfo: {
          originalTransactionId: "somebody-elses",
          autoRenewStatus: 1,
          gracePeriodExpiresDate: Date.now() + 3650 * DAY_MS,
        },
      }));

      expect((await statusAfter(env)).status).toBe("expired");
      expect((await statusAfter(env)).active).toBe(false);
    });

    it("ignores renewal info that names no transaction at all", async () => {
      const env = subscriptionEnv({ SUBSCRIPTION_GRACE_DAYS: "0" });
      await verify(env, [await signedTransaction({ signedDate: 1_000 })]);

      await notify(env, await signedNotification({
        notificationType: "DID_FAIL_TO_RENEW",
        transaction: { expiresDate: Date.now() - DAY_MS, signedDate: 2_000 },
        renewalInfo: {
          originalTransactionId: undefined,
          gracePeriodExpiresDate: Date.now() + 3650 * DAY_MS,
        },
      }));

      expect((await statusAfter(env)).status).toBe("expired");
    });

    it("ignores renewal info signed for another app", async () => {
      const env = subscriptionEnv({ SUBSCRIPTION_GRACE_DAYS: "0" });
      await verify(env, [await signedTransaction({ signedDate: 1_000 })]);

      await notify(env, await signedNotification({
        notificationType: "DID_FAIL_TO_RENEW",
        transaction: { expiresDate: Date.now() - DAY_MS, signedDate: 2_000 },
        renewalInfo: {
          bundleId: "com.example.someone-elses-app",
          gracePeriodExpiresDate: Date.now() + 3650 * DAY_MS,
        },
      }));

      expect((await statusAfter(env)).status).toBe("expired");
    });

    it("ignores sandbox renewal info reaching a production deployment", async () => {
      const env = subscriptionEnv({ SUBSCRIPTION_GRACE_DAYS: "0" });
      await verify(env, [await signedTransaction({ signedDate: 1_000 })]);

      await notify(env, await signedNotification({
        notificationType: "DID_FAIL_TO_RENEW",
        transaction: { expiresDate: Date.now() - DAY_MS, signedDate: 2_000 },
        renewalInfo: {
          environment: "Sandbox",
          gracePeriodExpiresDate: Date.now() + 3650 * DAY_MS,
        },
      }));

      expect((await statusAfter(env)).status).toBe("expired");
    });

    it("does not let a replayed older notification rewind the grace date", async () => {
      const env = subscriptionEnv({ SUBSCRIPTION_GRACE_DAYS: "0" });
      await verify(env, [await signedTransaction({ signedDate: 1_000 })]);

      await notify(env, await signedNotification({
        notificationType: "DID_FAIL_TO_RENEW",
        transaction: { expiresDate: Date.now() - DAY_MS, signedDate: 5_000 },
        renewalInfo: {
          signedDate: 5_000,
          autoRenewStatus: 1,
          gracePeriodExpiresDate: Date.now() + 5 * DAY_MS,
        },
      }));
      expect((await statusAfter(env)).status).toBe("grace");

      // Apple does not guarantee ordering, and anyone can post an old body
      // back. The stored state must not move backwards.
      await notify(env, await signedNotification({
        notificationType: "DID_FAIL_TO_RENEW",
        transaction: { expiresDate: Date.now() - DAY_MS, signedDate: 2_000 },
        renewalInfo: { signedDate: 2_000, autoRenewStatus: 0 },
      }));

      const after = await statusAfter(env);
      expect(after.status).toBe("grace");
      expect(after.autoRenew).toBe(true);
    });
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

  it("applies the default grace window when none is configured", async () => {
    // Number("") is 0, so an unset variable must not be allowed to fold into
    // the numeric check — that gives every deployment a zero-day window.
    env = subscriptionEnv();
    db = env.ZW_DB as unknown as FakeD1;
    db.seedSubscription({ expiresAtMs: Date.now() - DAY_MS });

    expect((await status()).status).toBe("grace");
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

  it("does not let a stored sandbox purchase grant access when sandbox testing is off", async () => {
    db.seedSubscription({ environment: "Sandbox" });

    expect((await status()).status).toBe("none");
  });

  it("lets the same stored sandbox purchase grant access while the opt-in is on", async () => {
    env = subscriptionEnv({ SUBSCRIPTION_SANDBOX_ENABLED: "true" });
    db = env.ZW_DB as unknown as FakeD1;
    db.seedSubscription({ environment: "Sandbox" });

    const state = await status();
    expect(state.active).toBe(true);
    expect(state.environment).toBe("Sandbox");
  });
});

describe("SUBSCRIPTION_REQUIRED enforcement", () => {
  function gatedEnv(overrides: Partial<Env> = {}): Env {
    return subscriptionEnv({ SUBSCRIPTION_REQUIRED: "true", ...overrides });
  }

  function upsert(env: Env): Promise<Response> {
    return (handler.fetch as any)(
      authedRequest("https://api.test/v1/cards/upsert", {
        method: "POST",
        body: JSON.stringify({ id: "solar", template: "summary", title: "Solar", value: "3.2" }),
      }),
      env,
      executionCtx,
    );
  }

  function listCards(env: Env): Promise<Response> {
    return (handler.fetch as any)(
      authedRequest("https://api.test/v1/cards"),
      env,
      executionCtx,
    );
  }

  it("refuses a publish from a tenant with no entitlement", async () => {
    const env = gatedEnv();

    const res = await upsert(env);

    expect(res.status).toBe(402);
    const body = await res.json() as any;
    expect(body.code).toBe("subscription_required");
    expect(body.subscription.status).toBe("none");
    // Written to be relayed by an agent to the person who can fix it.
    expect(body.error).toMatch(/subscribe in the iOS app/);
  });

  it("allows a publish from an entitled tenant", async () => {
    const env = gatedEnv();
    (env.ZW_DB as unknown as FakeD1).seedSubscription();

    expect((await upsert(env)).status).toBe(200);
  });

  it("allows a publish during the grace window", async () => {
    const env = gatedEnv();
    (env.ZW_DB as unknown as FakeD1).seedSubscription({ expiresAtMs: Date.now() - DAY_MS });

    expect((await upsert(env)).status).toBe(200);
  });

  it("refuses a publish once the entitlement is revoked", async () => {
    const env = gatedEnv();
    (env.ZW_DB as unknown as FakeD1).seedSubscription({ revokedAtMs: Date.now() - 1_000 });

    const res = await upsert(env);

    expect(res.status).toBe(402);
    expect((await res.json() as any).subscription.status).toBe("revoked");
  });

  it("leaves reads working for a lapsed tenant", async () => {
    const env = gatedEnv();

    // Widgets freezing at their last state is the intended failure mode. A
    // blank Lock Screen with no explanation is not.
    expect((await listCards(env)).status).toBe(200);
  });

  it("publishes normally when subscriptions are enabled but not required", async () => {
    const env = subscriptionEnv();

    expect((await upsert(env)).status).toBe(200);
  });

  it("fails open when REQUIRED is set without ENABLED", async () => {
    // A monetization kill switch that locks out every paying customer on a
    // typo is worse than one that bills nobody.
    const env = makeEnv({ SUBSCRIPTION_REQUIRED: "true" });

    expect((await upsert(env)).status).toBe(200);
  });

  it("changes nothing for a deployment that sets no flags at all", async () => {
    expect((await upsert(makeEnv())).status).toBe(200);
  });

  it("gates the MCP publish path, which does not route through authed()", async () => {
    // MCP re-implements its own scope check and calls handlers directly, so a
    // gate in `authed` alone would leave the agent-facing half of the product
    // ungated — the half that publishes.
    const env = gatedEnv({ MCP_ENABLED: "true", SESSION_SECRET: "test-session-secret-0123456789abcdef" });

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/mcp", {
        method: "POST",
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "upsert_card",
            arguments: { id: "solar", template: "summary", title: "Solar", value: "3.2" },
          },
        }),
      }),
      env,
      executionCtx,
    );

    const body = await res.json() as any;
    const text = (body.result?.content ?? []).map((entry: any) => entry.text).join("");
    expect(body.result?.isError).toBe(true);
    expect(text).toMatch(/subscription/i);
  });

  it("leaves the MCP read path working for a lapsed tenant", async () => {
    const env = gatedEnv({ MCP_ENABLED: "true", SESSION_SECRET: "test-session-secret-0123456789abcdef" });

    const res = await (handler.fetch as any)(
      authedRequest("https://api.test/mcp", {
        method: "POST",
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: { name: "list_cards", arguments: {} },
        }),
      }),
      env,
      executionCtx,
    );

    expect(((await res.json()) as any).result?.isError).toBeFalsy();
  });

  it("still lets a lapsed tenant prove they have renewed", async () => {
    const env = gatedEnv();

    // Gating the subscription routes themselves would make renewing impossible.
    const res = await verify(env, [await signedTransaction()]);

    expect(res.status).toBe(200);
    expect((await res.json() as any).subscription.active).toBe(true);
  });
});
