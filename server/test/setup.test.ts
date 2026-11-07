import { afterEach, describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import { __resetAppleJwksCache } from "../src/appleAuth";
import { issueAppCredentialBundle } from "../src/appCredentials";
import { putAppleAccount } from "../src/identity";
import { ApiScopePresets, createApiKey, revokeApiKey, sha256Hex } from "../src/auth";
import { APP_STORE_URL, readSetup, recordNativeSignIn, SetupSchema } from "../src/setup";
import * as storage from "../src/storage";
import type { Env } from "../src/types";
import { authedRequest, makeAppleIdToken, makeEnv, seedApiKey, TEST_API_KEY } from "./helpers";

const ctx = {} as ExecutionContext;
const ATTRIBUTES = "ZeroZeroWidgetActivityAttributes";
const TENANT = "test-tenant";
const fetchWorker = handler.fetch as (req: Request, env: Env, ctx: ExecutionContext) => Promise<Response>;

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  __resetAppleJwksCache();
});

async function marker(env: Env, tenant = TENANT) {
  return (await env.ZW_DB.prepare(`SELECT first_native_sign_in_at FROM tenants WHERE id = ?`)
    .bind(tenant).first<{ first_native_sign_in_at: string | null }>())?.first_native_sign_in_at;
}

async function enableDelivery(env: Env, tenant = TENANT) {
  await storage.putStartToken(env, tenant, "hash", "phone", ATTRIBUTES, `start-${tenant}`);
}

async function rpc(env: Env, method: string, params?: unknown, key = TEST_API_KEY) {
  const response = await fetchWorker(authedRequest("https://x/mcp", {
    method: "POST", body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  }, key), env, ctx);
  expect(response.status).toBe(200);
  return await response.json() as { result: Record<string, any> };
}

describe("native sign-in evidence", () => {
  it("keeps the first timestamp and isolates it from other accounts", async () => {
    const env = makeEnv();
    await seedApiKey(env, "second", "other");
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-11-01T10:00:00.000Z"));
    await recordNativeSignIn(env, TENANT);
    vi.setSystemTime(new Date("2026-11-07T10:00:00.000Z"));
    await recordNativeSignIn(env, TENANT);
    expect(await marker(env)).toBe("2026-11-01T10:00:00.000Z");
    expect(await marker(env, "other")).toBeNull();
  });

  it("does not mistake an Apple identity, partial bundle, or push registration for sign-in", async () => {
    const env = makeEnv();
    await putAppleAccount(env, { appleSub: "web-only", email: "test@example.com", tenantId: TENANT });
    await issueAppCredentialBundle(env, { tenantId: TENANT, ownerEmail: "test@example.com", label: "iOS" });
    await enableDelivery(env);
    expect(await marker(env)).toBeNull();
    expect((await readSetup(env, TENANT)).status).toBe("unknown");
  });

  it("records a successful native Apple exchange, but not a rejected exchange", async () => {
    const nonce = "native-login-nonce-0123456789";
    const clientId = "com.example.zerozerowidget";
    const env = makeEnv({ APPLE_APP_LOGIN_ENABLED: "true", APPLE_APP_SIGN_IN_CLIENT_ID: clientId });
    const { token, jwk } = await makeAppleIdToken({
      aud: clientId, sub: "native-user", email: "test-tenant@example.com", emailVerified: true,
      nonce: await sha256Hex(nonce),
    });
    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ keys: [jwk] })));
    const exchange = (rawNonce: string) => fetchWorker(new Request("https://x/v1/auth/apple/token", {
      method: "POST", body: JSON.stringify({ identityToken: token, nonce: rawNonce }),
    }), env, ctx);
    expect((await exchange("incorrect-nonce-0123456789")).status).toBe(401);
    expect(await marker(env)).toBeNull();
    expect((await exchange(nonce)).status).toBe(201);
    const first = await marker(env);
    expect(first).toBeTruthy();
    expect((await exchange(nonce)).status).toBe(201);
    expect(await marker(env)).toBe(first);
    expect((await readSetup(env, TENANT)).status).toBe("finish_setup");
  });
});

describe("advisory setup state", () => {
  it("recognises a native Horizon reader without requiring iPhone push registration", async () => {
    const env = makeEnv({ MCP_ENABLED: "true", SESSION_SECRET: "setup-test-secret-0123456789abcdef" });
    await createApiKey(env, { tenantId: TENANT, kind: "app", purpose: "device", scopes: ApiScopePresets.horizonApp });
    // Issuance alone cannot turn an unrecorded sign-in into completed setup.
    expect((await readSetup(env, TENANT)).status).toBe("unknown");
    await recordNativeSignIn(env, TENANT);
    expect(await readSetup(env, TENANT)).toEqual({ status: "ready", optional: true });
    for (const name of ["get_dashboard", "get_status"]) {
      const { result } = await rpc(env, "tools/call", { name, arguments: {} });
      expect(result.structuredContent.setup).toEqual({ status: "ready", optional: true });
    }
  });

  it.each(["revoked", "expired"])("offers Horizon guidance when its native credential is %s", async (state) => {
    const env = makeEnv();
    const native = await createApiKey(env, { tenantId: TENANT, kind: "app", purpose: "device", scopes: ApiScopePresets.horizonApp });
    await recordNativeSignIn(env, TENANT);
    if (state === "revoked") await revokeApiKey(env, native.apiKey.id);
    else {
      vi.useFakeTimers({ toFake: ["Date"] });
      vi.setSystemTime(new Date("2099-01-01T00:00:00Z"));
    }
    const setup = await readSetup(env, TENANT);
    expect(setup.status).toBe("finish_setup");
    expect(setup.appStoreUrl).toBeUndefined();
    expect(setup.instructions?.join(" ")).toContain("same Meta account");
    expect(setup.instructions?.join(" ")).not.toContain("same Apple account used to connect");
  });

  it("requires the configured entitlement for Horizon and never borrows another account's reader", async () => {
    const env = makeEnv({ SUBSCRIPTIONS_ENABLED: "true", SUBSCRIPTION_REQUIRED: "true" });
    await createApiKey(env, { tenantId: TENANT, kind: "app", purpose: "device", scopes: ApiScopePresets.horizonApp });
    await recordNativeSignIn(env, TENANT);
    expect((await readSetup(env, TENANT)).status).toBe("finish_setup");
    expect((await readSetup(env, TENANT)).instructions?.join(" ")).toContain("activate or restore");
    env.SUBSCRIPTION_REQUIRED = "false";
    expect((await readSetup(env, TENANT)).status).toBe("ready");
    await seedApiKey(env, "other", "other");
    await recordNativeSignIn(env, "other");
    expect((await readSetup(env, "other")).status).toBe("finish_setup");
  });

  it("transitions unknown → finish_setup → ready through the same existing tool", async () => {
    const env = makeEnv({ MCP_ENABLED: "true", SESSION_SECRET: "setup-test-secret-0123456789abcdef" });
    const call = async () => (await rpc(env, "tools/call", { name: "get_dashboard", arguments: {} })).result;
    const before = await call();
    expect(before.isError).toBeUndefined();
    expect(before.structuredContent).toMatchObject({ cards: [], activities: [], setup: { status: "unknown" } });
    await recordNativeSignIn(env, TENANT);
    expect((await call()).structuredContent.setup.status).toBe("finish_setup");
    await enableDelivery(env);
    const ready = await call();
    expect(ready.structuredContent).toEqual({ cards: [], activities: [], setup: { status: "ready", optional: true } });
    expect(JSON.parse(ready.content[0].text)).toEqual(ready.structuredContent);
  });

  it("accepts a widget or current start token, and rejects stale start tokens", async () => {
    const env = makeEnv();
    await recordNativeSignIn(env, TENANT);
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(Date.now() - 31 * 86400_000));
    await enableDelivery(env);
    vi.useRealTimers();
    expect((await readSetup(env, TENANT)).status).toBe("finish_setup");
    await storage.putWidgetToken(env, TENANT, "hash", "phone", "CardWidget", "widget");
    expect((await readSetup(env, TENANT)).status).toBe("ready");
  });

  it("requires a subscription only when publishing actually requires one", async () => {
    const env = makeEnv({ SUBSCRIPTIONS_ENABLED: "true", SUBSCRIPTION_REQUIRED: "false" });
    await recordNativeSignIn(env, TENANT);
    await enableDelivery(env);
    expect((await readSetup(env, TENANT)).status).toBe("ready");
    env.SUBSCRIPTION_REQUIRED = "true";
    expect((await readSetup(env, TENANT)).status).toBe("finish_setup");
    expect((await readSetup(env, TENANT)).instructions?.join(" ")).toContain("activate or restore");
    env.SUBSCRIPTIONS_ENABLED = "false";
    expect((await readSetup(env, TENANT)).status).toBe("ready");
  });

  it("does not use another account's sign-in, delivery tokens, or reviewer exemption", async () => {
    const env = makeEnv({
      REVIEW_TENANT_IDS: "other", MCP_ENABLED: "true", SESSION_SECRET: "setup-test-secret-0123456789abcdef",
    });
    await seedApiKey(env, "second", "other");
    await recordNativeSignIn(env, "other");
    await enableDelivery(env, "other");
    expect((await readSetup(env, TENANT)).status).toBe("unknown");
    await recordNativeSignIn(env, TENANT);
    expect((await readSetup(env, TENANT)).status).toBe("finish_setup");
    const read = async (key: string) => (await rpc(env, "tools/call", {
      name: "get_dashboard", arguments: {},
    }, key)).result.structuredContent.setup.status;
    expect(await read(TEST_API_KEY)).toBe("finish_setup");
    expect(await read("second")).toBe("ready");
  });

  it("recognises prepared reviewers without a personal device or purchase", async () => {
    const env = makeEnv({
      REVIEW_TENANT_IDS: TENANT, SUBSCRIPTIONS_ENABLED: "true", SUBSCRIPTION_REQUIRED: "true",
      MCP_ENABLED: "true", SESSION_SECRET: "setup-test-secret-0123456789abcdef",
    });
    expect(await readSetup(env, TENANT)).toEqual({ status: "ready", optional: true });
    const { result } = await rpc(env, "tools/call", {
      name: "upsert_card", arguments: { id: "review", template: "summary", title: "Reviewer access" },
    });
    expect(result.isError).toBeUndefined();
    expect(result.structuredContent.card.id).toBe("review");
    expect(await marker(env)).toBeNull();
    env.REVIEW_TENANT_IDS = "";
    expect((await readSetup(env, TENANT)).status).toBe("unknown");
  });

  it("provides optional guidance without disclosing profile or authentication details", async () => {
    const setup = SetupSchema.parse(await readSetup(makeEnv(), TENANT));
    expect(setup).toMatchObject({ status: "unknown", optional: true, appStoreUrl: APP_STORE_URL });
    expect(setup.question).toContain("Have you already configured");
    const text = setup.instructions!.join(" ");
    expect(text).toContain("same Apple account");
    expect(text).toContain("Keep the plugin or connector connected");
    expect(text).toContain("same tool again with the same arguments");
    expect(JSON.stringify(setup)).not.toMatch(/test-tenant|@|tokenHash|appleSub|first_native_sign_in_at/);
  });

  it("preserves existing read data and supplies setup in every existing data read and guide", async () => {
    const env = makeEnv({ MCP_ENABLED: "true", SESSION_SECRET: "setup-test-secret-0123456789abcdef" });
    await storage.putCard(env, TENANT, "hash", {
      id: "one", title: "Existing data", template: "summary", value: "42", status: "unknown", updatedAt: new Date().toISOString(),
    });
    const card = await storage.getCard(env, TENANT, "one");
    const reads: [string, Record<string, unknown>][] = [
      ["list_cards", {}], ["get_card", { id: "one" }], ["get_dashboard", {}],
      ["get_status", {}], ["list_live_activities", { includeEnded: true }],
      ["get_integration_guide", { section: "cards" }],
    ];
    for (const [name, args] of reads) {
      const { result } = await rpc(env, "tools/call", { name, arguments: args });
      expect(result.isError, name).toBeUndefined();
      SetupSchema.parse(result.structuredContent.setup);
      expect(result.structuredContent.setup.status, name).toBe("unknown");
      expect(result.content.some((item: { text: string }) => item.text.includes('"setup"')), name).toBe(true);
      if (name === "get_card") expect(result.structuredContent.card).toEqual(card);
      if (name === "list_cards" || name === "get_dashboard") expect(result.structuredContent.cards).toEqual([card]);
      if (name === "list_live_activities") expect(result.structuredContent).toMatchObject({ activities: [], ended: [] });
      if (name === "get_status") expect(result.structuredContent.account.tenantId).toBe(TENANT);
      if (name === "get_integration_guide") expect(result.structuredContent.markdown).toContain("# 00Widget — cards");
    }
    expect(await marker(env)).toBeNull();
  });

  it("never adds setup to discovery or blocks publishing for an unknown account", async () => {
    const env = makeEnv({ MCP_ENABLED: "true", SESSION_SECRET: "setup-test-secret-0123456789abcdef" });
    for (const method of ["initialize", "tools/list", "server/discover"]) {
      const result = await rpc(env, method);
      expect(JSON.stringify(result)).not.toContain('"setup"');
    }
    const { result } = await rpc(env, "tools/call", {
      name: "upsert_card", arguments: { id: "new", template: "summary", title: "Still allowed" },
    });
    expect(result.isError).toBeUndefined();
    expect(result.structuredContent.card.id).toBe("new");
    expect(result.structuredContent.setup).toBeUndefined();
  });

  it("preserves data when the optional setup lookup is unavailable", async () => {
    const env = makeEnv();
    const prepare = env.ZW_DB.prepare.bind(env.ZW_DB);
    vi.spyOn(env.ZW_DB, "prepare").mockImplementation((sql) => {
      if (sql.includes("SELECT first_native_sign_in_at")) throw new Error("lookup unavailable");
      return prepare(sql);
    });
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const response = await fetchWorker(authedRequest("https://x/v1/dashboard"), env, ctx);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ cards: [], activities: [], setup: { status: "unknown" } });
    expect(warn).toHaveBeenCalledWith("setup evidence unavailable");
  });
});
