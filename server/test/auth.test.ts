import { describe, it, expect } from "vitest";
import { requireAuth, AuthError, sha256Hex } from "../src/auth";
import { makeEnv } from "./helpers";

describe("requireAuth", () => {
  it("accepts a valid bearer token", async () => {
    const env = makeEnv({ API_KEYS: "alpha,beta" });
    const req = new Request("https://x/health", {
      headers: { authorization: "Bearer alpha" },
    });
    const ctx = await requireAuth(req, env);
    expect(ctx.apiKey).toBe("alpha");
    expect(ctx.apiKeyHash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("rejects missing header", async () => {
    await expect(requireAuth(new Request("https://x/"), makeEnv())).rejects.toBeInstanceOf(AuthError);
  });

  it("rejects wrong key", async () => {
    const req = new Request("https://x/", { headers: { authorization: "Bearer wrong" } });
    await expect(requireAuth(req, makeEnv())).rejects.toBeInstanceOf(AuthError);
  });

  it("rejects malformed header", async () => {
    const req = new Request("https://x/", { headers: { authorization: "Token abc" } });
    await expect(requireAuth(req, makeEnv())).rejects.toBeInstanceOf(AuthError);
  });

  it("rejects when no API_KEYS configured", async () => {
    const env = makeEnv({ API_KEYS: "" });
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
