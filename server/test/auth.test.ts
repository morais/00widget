import { describe, it, expect } from "vitest";
import {
  createApiKey,
  listApiKeys,
  requireAuth,
  revokeApiKey,
  AuthError,
  sha256Hex,
} from "../src/auth";
import { makeEnv } from "./helpers";

describe("requireAuth", () => {
  it("accepts a valid bearer token", async () => {
    const env = makeEnv();
    const req = new Request("https://x/health", {
      headers: { authorization: "Bearer test-key" },
    });
    const ctx = await requireAuth(req, env);
    expect(ctx.apiKey).toBe("test-key");
    expect(ctx.apiKeyHash).toMatch(/^[0-9a-f]{64}$/);
    expect(ctx.tenantId).toBe("test-tenant");
    expect((await listApiKeys(env)).find((key) => key.id === ctx.apiKeyId)?.lastUsedAt).toBeDefined();
  });

  it("rejects missing header", async () => {
    await expect(requireAuth(new Request("https://x/"), makeEnv())).rejects.toBeInstanceOf(AuthError);
  });

  it("rejects wrong key", async () => {
    const req = new Request("https://x/", { headers: { authorization: "Bearer wrong" } });
    await expect(requireAuth(req, makeEnv())).rejects.toBeInstanceOf(AuthError);
  });

  it("rejects revoked D1 API keys", async () => {
    const env = makeEnv();
    const created = await createApiKey(env, {
      ownerEmail: "revoked@example.com",
      label: "test",
    });
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

  it("rejects malformed header", async () => {
    const req = new Request("https://x/", { headers: { authorization: "Token abc" } });
    await expect(requireAuth(req, makeEnv())).rejects.toBeInstanceOf(AuthError);
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
