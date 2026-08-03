import { describe, it, expect, vi } from "vitest";
import handler from "../src/index";
import {
  ApiScopePresets,
  createApiKey,
  listApiKeys,
  requireAuth,
  revokeApiKey,
  AuthError,
  AuthRateLimitError,
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
