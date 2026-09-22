import { afterEach, describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import { readSessionCookie, resolveWebTenantIdentity } from "../src/webSession";
import type { Env } from "../src/types";
import { authedRequest, makeEnv, seedApiKey } from "./helpers";

const ORIGIN = "https://api.example.com";
const ctx = {} as ExecutionContext;
const SESSION_SECRET = "test-session-secret-0123456789abcdef";

function worker(req: Request, env: Env): Promise<Response> {
  return (handler.fetch as (req: Request, env: Env, ctx: ExecutionContext) => Promise<Response>)(req, env, ctx);
}

function horizonEnv(overrides: Partial<Env> = {}): Env {
  return makeEnv({
    HORIZON_IDENTITY_ENABLED: "true",
    META_APP_ID: "meta-app-123",
    META_APP_SECRET: "server-secret",
    SESSION_SECRET,
    ...overrides,
  });
}

async function createHorizonAccount(env: Env): Promise<{ token: string; tenantId: string }> {
  vi.stubGlobal("fetch", vi.fn(async () => Response.json({ is_valid: true })));
  const created = await worker(new Request(`${ORIGIN}/v1/auth/horizon`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.30" },
    body: JSON.stringify({ userId: "meta-user-1", userProof: "proof-browser-123456", choice: "create" }),
  }), env);
  expect(created.status).toBe(201);
  const token = (await created.json() as { token: string }).token;
  const account = await worker(authedRequest(`${ORIGIN}/v1/account`, {}, token), env);
  const tenantId = (await account.json() as { account: { tenantId: string } }).account.tenantId;
  return { token, tenantId };
}

async function start(env: Env, next = "/connect/mcp/authorize?client_id=test"): Promise<{ code: string; cookie: string }> {
  const response = await worker(new Request(`${ORIGIN}/login/horizon?next=${encodeURIComponent(next)}`, {
    headers: { "cf-connecting-ip": "192.0.2.31" },
  }), env);
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("no-store");
  const body = await response.text();
  const code = body.match(/<code>([A-Z0-9]{4}-[A-Z0-9]{4})<\/code>/)?.[1];
  expect(code).toBeTruthy();
  const cookie = response.headers.get("set-cookie")!.split(";")[0];
  return { code: code!, cookie };
}

afterEach(() => vi.unstubAllGlobals());

describe("Horizon browser sign-in", () => {
  it("is off without identity or a strong session secret", async () => {
    const disabled = await worker(new Request(`${ORIGIN}/login/horizon`), makeEnv());
    expect(disabled.status).toBe(404);
    const weak = await worker(new Request(`${ORIGIN}/login/horizon`), horizonEnv({ SESSION_SECRET: "weak" }));
    expect(weak.status).toBe(404);
  });

  it("binds approval to the browser, creates a revalidated session, and consumes the code once", async () => {
    const env = horizonEnv();
    const { token, tenantId } = await createHorizonAccount(env);
    const { code, cookie } = await start(env);

    const pending = await worker(new Request(`${ORIGIN}/login/horizon/complete`, {
      headers: { cookie },
    }), env);
    expect(pending.status).toBe(200);
    expect(await pending.text()).toContain("Waiting for your headset");

    const approved = await worker(authedRequest(`${ORIGIN}/v1/auth/horizon/browser/approve`, {
      method: "POST",
      body: JSON.stringify({ code }),
    }, token), env);
    expect(approved.status).toBe(200);
    expect(await approved.json()).toEqual({ ok: true, status: "approved" });

    const consumed = await worker(new Request(`${ORIGIN}/login/horizon/complete`, {
      headers: { cookie },
    }), env);
    expect(consumed.status).toBe(302);
    expect(consumed.headers.get("location")).toBe("/connect/mcp/authorize?client_id=test");
    const sessionCookie = consumed.headers.get("set-cookie")!.match(/zw_session=[^;]+/)?.[0];
    expect(sessionCookie).toBeTruthy();
    const principal = await readSessionCookie(env, new Request(`${ORIGIN}/connect/mcp/authorize`, {
      headers: { cookie: sessionCookie! },
    }));
    expect(principal).toMatchObject({ method: "horizon", tenantId, isAdmin: false });
    expect(await resolveWebTenantIdentity(env, principal!)).toEqual({ tenantId, ownerEmail: null });
    expect(await readSessionCookie({ ...env, HORIZON_IDENTITY_ENABLED: "false" }, new Request(`${ORIGIN}/`, {
      headers: { cookie: sessionCookie! },
    }))).toBeNull();

    const replay = await worker(new Request(`${ORIGIN}/login/horizon/complete`, {
      headers: { cookie },
    }), env);
    expect(replay.status).toBe(410);
    const secondApproval = await worker(authedRequest(`${ORIGIN}/v1/auth/horizon/browser/approve`, {
      method: "POST",
      body: JSON.stringify({ code }),
    }, token), env);
    expect(secondApproval.status).toBe(409);

    const deleted = await worker(authedRequest(`${ORIGIN}/v1/account`, { method: "DELETE" }, token), env);
    expect(deleted.status).toBe(200);
    expect(await readSessionCookie(env, new Request(`${ORIGIN}/`, {
      headers: { cookie: sessionCookie! },
    }))).toBeNull();
  });

  it("cannot approve from an unrelated account and supports explicit denial", async () => {
    const env = horizonEnv();
    const { token } = await createHorizonAccount(env);
    await seedApiKey(env, "unrelated-app", "other-tenant", "app");
    const { code, cookie } = await start(env, "https://evil.example/");

    const unrelated = await worker(authedRequest(`${ORIGIN}/v1/auth/horizon/browser/approve`, {
      method: "POST",
      body: JSON.stringify({ code }),
    }, "unrelated-app"), env);
    expect(unrelated.status).toBe(403);

    const denied = await worker(authedRequest(`${ORIGIN}/v1/auth/horizon/browser/approve`, {
      method: "POST",
      body: JSON.stringify({ code, decision: "deny" }),
    }, token), env);
    expect(denied.status).toBe(200);
    expect(await denied.json()).toEqual({ ok: true, status: "denied" });
    const completion = await worker(new Request(`${ORIGIN}/login/horizon/complete`, {
      headers: { cookie },
    }), env);
    expect(completion.status).toBe(403);
  });
});
