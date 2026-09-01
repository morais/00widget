import { describe, expect, it } from "vitest";
import handler from "../src/index";
import { readSessionCookie } from "../src/webSession";
import type { Env } from "../src/types";
import { makeEnv, seedApiKey, testApiKey } from "./helpers";

const ctx = {} as ExecutionContext;
const ORIGIN = "https://api.example.com";
const SESSION_SECRET = "test-session-secret-0123456789abcdef";
const REVIEW_TENANT = "openai-review";
const REVIEW_CODE = testApiKey("openai-review-code");

function fetchWorker(req: Request, env: Env): Promise<Response> {
  return (handler.fetch as (r: Request, e: Env, c: ExecutionContext) => Promise<Response>)(
    req,
    env,
    ctx,
  );
}

function reviewEnv(overrides: Partial<Env> = {}): Env {
  return makeEnv({
    MCP_ENABLED: "true",
    SESSION_SECRET,
    REVIEW_TENANT_IDS: REVIEW_TENANT,
    ...overrides,
  });
}

async function seedReviewCode(env: Env): Promise<void> {
  await seedApiKey(env, REVIEW_CODE, REVIEW_TENANT, "publisher", "", "", undefined, []);
}

function sessionCookieFrom(res: Response): string | undefined {
  return res.headers
    .getSetCookie()
    .map((value) => value.split(";")[0])
    .find((value) => value.startsWith("zw_session="));
}

describe("review login", () => {
  it("publishes only whether the allowlist is enabled", async () => {
    const disabled = await fetchWorker(new Request(`${ORIGIN}/v1/auth/review/config`), makeEnv());
    expect(await disabled.json()).toEqual({ enabled: false });

    const enabled = await fetchWorker(
      new Request(`${ORIGIN}/v1/auth/review/config`),
      reviewEnv(),
    );
    expect(await enabled.json()).toEqual({ enabled: true });
    expect(enabled.headers.get("cache-control")).toBe("no-store");
  });

  it("exchanges a zero-scope allowlisted code for the normal app bundle", async () => {
    const env = reviewEnv();
    await seedReviewCode(env);

    const res = await fetchWorker(
      new Request(`${ORIGIN}/v1/auth/review/token`, {
        method: "POST",
        headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.41" },
        body: JSON.stringify({
          accessCode: REVIEW_CODE,
          label: "Review iPhone",
          deviceId: "review-device",
        }),
      }),
      env,
    );

    expect(res.status).toBe(201);
    const body = await res.json() as Record<string, unknown>;
    expect((body.tenant as { id: string }).id).toBe(REVIEW_TENANT);
    expect(body.token).toMatch(/^zw_/);
    expect(body.appCredential).toMatch(/^zwa_/);
    expect(body.publisherCredential).toMatch(/^zw_/);
  });

  it("rejects an ordinary scoped API token, even for an allowlisted tenant", async () => {
    const env = reviewEnv();
    await seedApiKey(env, REVIEW_CODE, REVIEW_TENANT);
    const res = await fetchWorker(
      new Request(`${ORIGIN}/v1/auth/review/token`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ accessCode: REVIEW_CODE }),
      }),
      env,
    );
    expect(res.status).toBe(401);
  });

  it("shows the discreet web option only for MCP authorization and binds its session", async () => {
    const env = reviewEnv({ ADMIN_EMAILS: `${REVIEW_TENANT}@example.com` });
    await seedReviewCode(env);
    const next = "/connect/mcp/authorize?client_id=example";

    const ordinary = await fetchWorker(new Request(`${ORIGIN}/login`), env);
    expect(await ordinary.text()).not.toContain("Reviewer access");
    const login = await fetchWorker(
      new Request(`${ORIGIN}/login?next=${encodeURIComponent(next)}`),
      env,
    );
    expect(await login.text()).toContain("Reviewer access");

    const res = await fetchWorker(
      new Request(`${ORIGIN}/login/review-token`, {
        method: "POST",
        headers: {
          origin: ORIGIN,
          "content-type": "application/x-www-form-urlencoded",
          "cf-connecting-ip": "203.0.113.42",
        },
        body: new URLSearchParams({ next, accessCode: REVIEW_CODE }),
      }),
      env,
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(next);
    const cookie = sessionCookieFrom(res);
    expect(cookie).toBeDefined();
    const session = await readSessionCookie(
      env,
      new Request(`${ORIGIN}/`, { headers: { cookie: cookie! } }),
    );
    expect(session?.method).toBe("review-token");
    expect(session?.tenantId).toBe(REVIEW_TENANT);
    expect(session?.isAdmin).toBe(false);
  });

  it("protects an allowlisted review tenant from account deletion", async () => {
    const env = reviewEnv();
    const appToken = testApiKey("review-app-token").replace(/^zw_/, "zwa_");
    await seedApiKey(env, appToken, REVIEW_TENANT, "app");
    const res = await fetchWorker(
      new Request(`${ORIGIN}/v1/account`, {
        method: "DELETE",
        headers: { authorization: `Bearer ${appToken}` },
      }),
      env,
    );
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "review tenants cannot be deleted" });
  });
});
