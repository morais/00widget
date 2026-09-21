import { describe, expect, it } from "vitest";
import handler from "../src/index";
import type { Env } from "../src/types";
import { authedRequest, makeEnv, seedApiKey, testApiKey } from "./helpers";

const ORIGIN = "https://api.example.com";
const ctx = {} as ExecutionContext;

function fetchWorker(req: Request, env: Env): Promise<Response> {
  return (handler.fetch as (r: Request, e: Env, c: ExecutionContext) => Promise<Response>)(
    req,
    env,
    ctx,
  );
}

async function issue(env: Env): Promise<{
  device_code: string;
  user_code: string;
  verification_uri: string;
  verification_uri_complete: string;
  expires_in: number;
  interval: number;
}> {
  const response = await fetchWorker(new Request(`${ORIGIN}/v1/auth/device/code`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.1" },
    body: "{}",
  }), env);
  expect(response.status).toBe(201);
  return response.json() as Promise<any>;
}

describe("Horizon device authorization", () => {
  it("is disabled unless explicitly enabled", async () => {
    const response = await fetchWorker(new Request(`${ORIGIN}/v1/auth/device/code`, {
      method: "POST",
      body: "{}",
    }), makeEnv());
    expect(response.status).toBe(404);
  });

  it("issues a short code and a Universal Link without exposing the device secret", async () => {
    const env = makeEnv({ HORIZON_DEVICE_AUTH_ENABLED: "true" });
    const code = await issue(env);
    expect(code.device_code).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(code.user_code).toMatch(/^[23456789A-HJ-NP-Z]{4}-[23456789A-HJ-NP-Z]{4}$/);
    expect(code.verification_uri).toBe(`${ORIGIN}/device`);
    expect(code.verification_uri_complete).toBe(`${ORIGIN}/app/device?code=${code.user_code}`);
    expect(code.verification_uri_complete).not.toContain(code.device_code);
    expect(code.expires_in).toBe(600);
    expect(code.interval).toBe(5);
  });

  it("stays pending until an app credential approves, then mints one device token", async () => {
    const env = makeEnv({ HORIZON_DEVICE_AUTH_ENABLED: "true" });
    await seedApiKey(env, "phone-app", "owner", "app");
    const code = await issue(env);

    const pending = await fetchWorker(new Request(`${ORIGIN}/v1/auth/device/token`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.2" },
      body: JSON.stringify({ device_code: code.device_code }),
    }), env);
    expect(await pending.json()).toEqual({ error: "authorization_pending" });

    const approved = await fetchWorker(authedRequest(`${ORIGIN}/v1/auth/device/approve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ user_code: code.user_code.toLowerCase() }),
    }, "phone-app"), env);
    expect(approved.status).toBe(200);
    expect(await approved.json()).toEqual({ ok: true });

    const exchanged = await fetchWorker(new Request(`${ORIGIN}/v1/auth/device/token`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.2" },
      body: JSON.stringify({ device_code: code.device_code }),
    }), env);
    const body = await exchanged.json() as { token: string };
    expect(body.token).toMatch(/^zw_[A-Za-z0-9_-]{43}$/);

    const cards = await fetchWorker(new Request(`${ORIGIN}/v1/cards`, {
      headers: { authorization: `Bearer ${body.token}` },
    }), env);
    expect(cards.status).toBe(200);
    const publish = await fetchWorker(new Request(`${ORIGIN}/v1/cards/upsert`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${body.token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ id: "forbidden", title: "No", template: "summary" }),
    }), env);
    expect(publish.status).toBe(403);

    const replay = await fetchWorker(new Request(`${ORIGIN}/v1/auth/device/token`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.2" },
      body: JSON.stringify({ device_code: code.device_code }),
    }), env);
    expect(await replay.json()).toEqual({ error: "expired" });
  });

  it("requires an app credential for native approval", async () => {
    const env = makeEnv({ HORIZON_DEVICE_AUTH_ENABLED: "true" });
    await seedApiKey(env, "publisher", "owner", "publisher");
    const code = await issue(env);
    const response = await fetchWorker(new Request(`${ORIGIN}/v1/auth/device/approve`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${testApiKey("publisher")}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ user_code: code.user_code }),
    }), env);
    expect(response.status).toBe(403);
  });

  it("serves the browser fallback and preserves the code through Apple login", async () => {
    const env = makeEnv({
      HORIZON_DEVICE_AUTH_ENABLED: "true",
      SESSION_SECRET: "test-session-secret-0123456789abcdef",
      APPLE_SIGN_IN_CLIENT_ID: "com.example.signin",
      APPLE_SIGN_IN_REDIRECT_URI: `${ORIGIN}/auth/apple/callback`,
    });
    const code = await issue(env);
    const response = await fetchWorker(
      new Request(code.verification_uri_complete),
      env,
    );
    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toContain(
      encodeURIComponent(`/app/device?code=${code.user_code}`),
    );
  });
});
