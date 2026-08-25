import { describe, it, expect, vi } from "vitest";
import handler from "../src/index";
import {
  ApiScopePresets,
  createApiKey,
  DEFAULT_TOKEN_LIFETIME_SECONDS,
  listApiKeys,
  requireAuth,
  revokeApiKey,
  AuthError,
  AuthRateLimitError,
  createTenantForOwner,
  TenantEmailTakenError,
  sha256Hex,
} from "../src/auth";
import {
  authedRequest,
  FakeRateLimit,
  makeEnv,
  seedApiKey,
  TEST_API_KEY,
  testApiKey,
} from "./helpers";

const executionCtx = {} as ExecutionContext;

describe("requireAuth", () => {
  it("accepts a valid bearer token", async () => {
    const env = makeEnv();
    const req = new Request("https://x/health", {
      headers: {
        authorization: `Bearer ${TEST_API_KEY}`,
        "cf-connecting-ip": "203.0.113.10",
      },
    });
    const ctx = await requireAuth(req, env);
    expect(ctx.apiKey).toBe(TEST_API_KEY);
    expect(ctx.apiKeyHash).toMatch(/^[0-9a-f]{64}$/);
    expect(ctx.tenantId).toBe("test-tenant");
    expect(ctx.credentialKind).toBe("publisher");
    expect(ctx.scopes).toEqual(ApiScopePresets.legacyPublisher);
    expect((env.AUTH_SOURCE_LIMITER as unknown as FakeRateLimit).calls).toEqual([
      "source:203.0.113.10",
    ]);
    expect((env.AUTH_TOKEN_LIMITER as unknown as FakeRateLimit).calls).toEqual([
      `token:${ctx.apiKeyHash}`,
    ]);
    expect((await listApiKeys(env)).find((key) => key.id === ctx.apiKeyId)?.lastUsedAt).toBeDefined();
  });

  it("rejects missing header", async () => {
    await expect(requireAuth(new Request("https://x/"), makeEnv())).rejects.toBeInstanceOf(AuthError);
  });

  it("rejects wrong key", async () => {
    const req = new Request("https://x/", {
      headers: { authorization: `Bearer ${testApiKey("wrong")}` },
    });
    await expect(requireAuth(req, makeEnv())).rejects.toBeInstanceOf(AuthError);
  });

  it("rejects malformed tokens before rate limiting or D1", async () => {
    const env = makeEnv();
    const prepare = vi.spyOn(env.ZW_DB, "prepare");
    const req = new Request("https://x/", {
      headers: { authorization: "Bearer arbitrary-attacker-input" },
    });

    await expect(requireAuth(req, env)).rejects.toMatchObject({ message: "invalid API key" });
    expect((env.AUTH_SOURCE_LIMITER as unknown as FakeRateLimit).calls).toEqual([]);
    expect((env.AUTH_TOKEN_LIMITER as unknown as FakeRateLimit).calls).toEqual([]);
    expect(prepare).not.toHaveBeenCalled();
  });

  it("rejects source-IP floods before D1", async () => {
    const env = makeEnv();
    (env.AUTH_SOURCE_LIMITER as unknown as FakeRateLimit).success = false;
    const prepare = vi.spyOn(env.ZW_DB, "prepare");

    await expect(requireAuth(authedRequest("https://x/v1/cards"), env))
      .rejects.toBeInstanceOf(AuthRateLimitError);
    expect(prepare).not.toHaveBeenCalled();
  });

  it("rejects token floods before D1", async () => {
    const env = makeEnv();
    (env.AUTH_TOKEN_LIMITER as unknown as FakeRateLimit).success = false;
    const prepare = vi.spyOn(env.ZW_DB, "prepare");

    await expect(requireAuth(authedRequest("https://x/v1/cards"), env))
      .rejects.toBeInstanceOf(AuthRateLimitError);
    expect(prepare).not.toHaveBeenCalled();
  });

  it("returns 429 and Retry-After when an auth limiter blocks", async () => {
    const env = makeEnv();
    (env.AUTH_SOURCE_LIMITER as unknown as FakeRateLimit).success = false;

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards"),
      env,
      executionCtx,
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    await expect(response.json()).resolves.toEqual({ error: "too many authentication attempts" });
  });

  it("rejects revoked D1 API keys", async () => {
    const env = makeEnv();
    const created = await createApiKey(env, {
      ownerEmail: "revoked@example.com",
      label: "test",
    });
    expect(created.apiKey.scopes).toEqual(ApiScopePresets.producer);
    const req = new Request("https://x/", {
      headers: { authorization: `Bearer ${created.token}` },
    });
    await expect(requireAuth(req, env)).resolves.toMatchObject({
      tenantId: created.tenant.id,
      apiKeyId: created.apiKey.id,
    });

    await revokeApiKey(env, created.apiKey.id);
    await expect(requireAuth(req, env)).rejects.toBeInstanceOf(AuthError);
  });

  it("defaults app credentials to app-only scopes", async () => {
    const env = makeEnv();
    const created = await createApiKey(env, {
      ownerEmail: "app@example.com",
      label: "app",
      kind: "app",
    });

    expect(created.apiKey.scopes).toEqual(ApiScopePresets.appOnly);
  });

  it("rejects malformed header", async () => {
    const req = new Request("https://x/", { headers: { authorization: "Token abc" } });
    await expect(requireAuth(req, makeEnv())).rejects.toBeInstanceOf(AuthError);
  });

  it("rejects expired API keys", async () => {
    const env = makeEnv();
    await seedApiKey(
      env,
      "expired-key",
      "test-tenant",
      "publisher",
      "",
      "",
      "2020-01-01T00:00:00.000Z",
    );
    const req = new Request("https://x/", {
      headers: { authorization: `Bearer ${testApiKey("expired-key")}` },
    });
    await expect(requireAuth(req, env)).rejects.toMatchObject({ message: "API key expired" });
  });

  it("renews a credential on use so an integration is never re-keyed", async () => {
    const env = makeEnv();
    // 30 days out and sliding on a 90-day window: use should push it forward.
    const before = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
    await seedApiKey(env, "sliding", "test-tenant", "publisher", "", "", before);
    const req = new Request("https://x/", {
      headers: { authorization: `Bearer ${testApiKey("sliding")}` },
    });

    const ctx = await requireAuth(req, env);
    const renewed = (await listApiKeys(env)).find((key) => key.id === ctx.apiKeyId)!;

    expect(Date.parse(renewed.expiresAt)).toBeGreaterThan(Date.parse(before));
    // Renewal extends the existing row; the token itself is untouched, which is
    // the whole point — nothing downstream has to be handed a new value.
    expect(ctx.apiKey).toBe(testApiKey("sliding"));
    expect(renewed.expiresAt).toBe(
      new Date(Date.parse(renewed.lastUsedAt!) + DEFAULT_TOKEN_LIFETIME_SECONDS * 1000).toISOString(),
    );
  });

  it("expires a credential that goes idle past its window", async () => {
    const env = makeEnv();
    // Last used long ago and already past its deadline: nothing renews it,
    // because renewal only ever happens on a *successful* authentication.
    await seedApiKey(
      env,
      "idle",
      "test-tenant",
      "publisher",
      "",
      "",
      "2020-01-01T00:00:00.000Z",
    );
    const req = new Request("https://x/", {
      headers: { authorization: `Bearer ${testApiKey("idle")}` },
    });
    await expect(requireAuth(req, env)).rejects.toMatchObject({ message: "API key expired" });
  });

  it("never renews a credential the operator gave a fixed deadline", async () => {
    const env = makeEnv();
    const fixed = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();
    await seedApiKey(env, "fixed", "test-tenant", "publisher", "", "", fixed, undefined, null);
    const req = new Request("https://x/", {
      headers: { authorization: `Bearer ${testApiKey("fixed")}` },
    });

    const ctx = await requireAuth(req, env);
    const after = (await listApiKeys(env)).find((key) => key.id === ctx.apiKeyId)!;

    expect(after.expiresAt).toBe(fixed);
    expect(after.lastUsedAt).toBeDefined();
  });

  it("never shortens an expiry that is already further out", async () => {
    const env = makeEnv();
    // The default seed expiry (2099) is far beyond the 90-day sliding window,
    // so MAX() must keep it rather than pulling it back.
    await seedApiKey(env, "faraway", "test-tenant");
    const req = new Request("https://x/", {
      headers: { authorization: `Bearer ${testApiKey("faraway")}` },
    });

    const ctx = await requireAuth(req, env);
    const after = (await listApiKeys(env)).find((key) => key.id === ctx.apiKeyId)!;

    expect(after.expiresAt).toBe("2099-01-01T00:00:00.000Z");
  });

  it("does not revive an expired credential admitted for sign-out", async () => {
    const env = makeEnv();
    const expired = "2020-01-01T00:00:00.000Z";
    await seedApiKey(env, "signout", "test-tenant", "publisher", "", "", expired);
    const req = new Request("https://x/", {
      headers: { authorization: `Bearer ${testApiKey("signout")}` },
    });

    // The sign-out route admits expired credentials so a lapsed token can still
    // clean up after itself — but that must not extend its life.
    const ctx = await requireAuth(req, env, { allowExpired: true });
    const after = (await listApiKeys(env)).find((key) => key.id === ctx.apiKeyId)!;

    expect(after.expiresAt).toBe(expired);
  });

  it("does not accept API_KEYS env values that are not stored in D1", async () => {
    const env = makeEnv({ API_KEYS: "env-only" });
    const req = new Request("https://x/", { headers: { authorization: "Bearer x" } });
    await expect(requireAuth(req, env)).rejects.toBeInstanceOf(AuthError);
  });

  it("produces stable sha256 hashes", async () => {
    const a = await sha256Hex("hello");
    const b = await sha256Hex("hello");
    expect(a).toBe(b);
    expect(a).not.toBe(await sha256Hex("world"));
  });
});


// One address, one tenant (migrations/0030). Enforced by a unique index, which
// `INSERT OR IGNORE` swallows exactly as quietly as it swallows a repeated id —
// so the write paths read `changes` to tell a refusal from a no-op.
describe("a tenant's owner email is unique", () => {
  it("refuses to create a second tenant for an address that has one", async () => {
    const env = makeEnv();
    const first = await createApiKey(env, { ownerEmail: "person@example.com" });
    expect(first.tenant.id).toBeTruthy();

    await expect(createApiKey(env, { ownerEmail: "Person@Example.com" }))
      .rejects.toThrow(TenantEmailTakenError);
  });

  it("leaves no credential behind when it refuses", async () => {
    // The failure this guards. Without the check, `OR IGNORE` skipped the
    // tenant row and the function carried on to insert an api_keys row against
    // a tenant id that does not exist — a token handed to an operator once
    // that fails its very first request, because requireAuth joins tenants.
    const env = makeEnv();
    await createApiKey(env, { ownerEmail: "person@example.com" });
    const before = (await listApiKeys(env)).length;

    await expect(createApiKey(env, { ownerEmail: "person@example.com" }))
      .rejects.toThrow(TenantEmailTakenError);

    expect((await listApiKeys(env)).length).toBe(before);
  });

  it("still mints a credential for a tenant that already exists", async () => {
    // The id path must keep working: `OR IGNORE` returning 0 for an existing
    // tenant is the normal case, not a refusal.
    const env = makeEnv();
    const first = await createApiKey(env, { ownerEmail: "person@example.com" });

    const second = await createApiKey(env, { tenantId: first.tenant.id, label: "second" });

    expect(second.tenant.id).toBe(first.tenant.id);
    expect(second.token).toMatch(/^zw_/);
  });

  it("refuses a fresh tenant for a taken address", async () => {
    const env = makeEnv();
    await createApiKey(env, { ownerEmail: "person@example.com" });

    await expect(createTenantForOwner(env, "person@example.com"))
      .rejects.toThrow(TenantEmailTakenError);
  });

  it("lets a disabled tenant release its address", async () => {
    // The partial index is what makes retiring and re-provisioning possible.
    const env = makeEnv();
    const first = await createApiKey(env, { ownerEmail: "person@example.com" });
    (env.ZW_DB as unknown as { disableTenant(id: string): void }).disableTenant(first.tenant.id);

    const replacement = await createTenantForOwner(env, "person@example.com");

    expect(replacement.id).not.toBe(first.tenant.id);
  });
});
