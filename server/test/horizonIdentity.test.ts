import { afterEach, describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import { putAppleAccount } from "../src/identity";
import type { Env } from "../src/types";
import { authedRequest, makeEnv, seedApiKey } from "./helpers";

const ORIGIN = "https://api.example.com";
const ctx = {} as ExecutionContext;

function horizonEnv(overrides: Partial<Env> = {}): Env {
  return makeEnv({
    HORIZON_IDENTITY_ENABLED: "true",
    HORIZON_DEVICE_AUTH_ENABLED: "true",
    META_APP_ID: "meta-app-123",
    META_APP_SECRET: "server-secret",
    ...overrides,
  });
}

function worker(req: Request, env: Env): Promise<Response> {
  return (handler.fetch as (req: Request, env: Env, ctx: ExecutionContext) => Promise<Response>)(
    req, env, ctx,
  );
}

function login(
  env: Env,
  userProof: string,
  choice?: "create" | "join_apple",
  userId = "123456789",
): Promise<Response> {
  return worker(new Request(`${ORIGIN}/v1/auth/horizon`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.17" },
    body: JSON.stringify({ userId, userProof, ...(choice ? { choice } : {}) }),
  }), env);
}

function verifiedMeta(): ReturnType<typeof vi.fn> {
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    expect(String(input)).toBe("https://graph.oculus.com/user_nonce_validate");
    expect(init?.method).toBe("POST");
    const form = new URLSearchParams(String(init?.body));
    expect(form.get("access_token")).toBe("OC|meta-app-123|server-secret");
    expect(form.get("user_id")).toBeTruthy();
    expect(form.get("nonce")).toBeTruthy();
    return Response.json({ is_valid: true });
  });
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

afterEach(() => vi.unstubAllGlobals());

describe("Horizon identity", () => {
  it("is disabled until explicitly configured and rejects invalid Meta proof", async () => {
    const disabled = await login(makeEnv(), "proof-12345678");
    expect(disabled.status).toBe(404);

    const missingSecret = await login(horizonEnv({ META_APP_SECRET: undefined }), "proof-12345678");
    expect(missingSecret.status).toBe(503);

    vi.stubGlobal("fetch", vi.fn(async () => Response.json({ is_valid: false })));
    const denied = await login(horizonEnv(), "proof-12345678", "create");
    expect(denied.status).toBe(401);
  });

  it("retires anonymous phone pairing when verified Horizon identity is enabled", async () => {
    const env = horizonEnv();
    const anonymous = await worker(new Request(`${ORIGIN}/v1/auth/device/code`, {
      method: "POST",
      body: "{}",
    }), env);
    expect(anonymous.status).toBe(404);
  });

  it("requires a choice, creates an account without email, and signs in the same Meta user", async () => {
    const env = horizonEnv();
    const fetchMock = verifiedMeta();

    const choice = await login(env, "proof-first-12345678");
    expect(choice.status).toBe(200);
    expect(await choice.json()).toEqual({
      status: "choice_required",
      choices: ["create", "join_apple"],
    });
    expect((await login(env, "proof-first-12345678", "create")).status).toBe(409);

    const created = await login(env, "proof-create-12345678", "create");
    expect(created.status).toBe(201);
    const token = (await created.json() as { token: string }).token;
    expect(token).toMatch(/^zwa_[A-Za-z0-9_-]{43}$/);

    const accountResponse = await worker(authedRequest(`${ORIGIN}/v1/account`, {}, token), env);
    expect(accountResponse.status).toBe(200);
    const account = (await accountResponse.json() as any).account;
    expect(account).toMatchObject({ ownerEmail: null, displayName: "Horizon account" });
    expect(account.identities).toEqual([{ provider: "horizon" }]);
    expect(account.tenantId).toBeTruthy();

    const cannotUnlink = await worker(authedRequest(`${ORIGIN}/v1/account/horizon`, {
      method: "DELETE",
    }, token), env);
    expect(cannotUnlink.status).toBe(409);

    const signedIn = await login(env, "proof-return-12345678");
    expect(signedIn.status).toBe(201);
    const secondToken = (await signedIn.json() as { token: string }).token;
    const secondAccount = await worker(authedRequest(`${ORIGIN}/v1/account`, {}, secondToken), env);
    expect((await secondAccount.json() as any).account.tenantId).toBe(account.tenantId);
    expect(fetchMock).toHaveBeenCalledTimes(4);

    const deleted = await worker(authedRequest(`${ORIGIN}/v1/account`, {
      method: "DELETE",
    }, token), env);
    expect(deleted.status).toBe(200);
    expect((await login(env, "proof-after-delete-12345678")).status).toBe(200);
  });

  it("links a verified Meta identity only after explicit Apple account approval", async () => {
    const env = horizonEnv();
    verifiedMeta();
    await seedApiKey(env, "phone-app", "apple-owner", "app");
    await seedApiKey(env, "unlinked-app", "no-apple-owner", "app");
    await putAppleAccount(env, {
      appleSub: "apple-sub-1",
      tenantId: "apple-owner",
      email: "apple-owner@example.com",
    });

    const link = await login(env, "proof-join-12345678", "join_apple");
    expect(link.status).toBe(201);
    const code = await link.json() as { device_code: string; user_code: string };
    expect(code.user_code).toMatch(/^[A-Z0-9]{4}-[A-Z0-9]{4}$/);

    const unlinked = await worker(authedRequest(`${ORIGIN}/v1/auth/device/approve`, {
      method: "POST",
      body: JSON.stringify({ user_code: code.user_code }),
    }, "unlinked-app"), env);
    expect(unlinked.status).toBe(403);

    const approved = await worker(authedRequest(`${ORIGIN}/v1/auth/device/approve`, {
      method: "POST",
      body: JSON.stringify({ user_code: code.user_code }),
    }, "phone-app"), env);
    expect(approved.status).toBe(200);

    const exchanged = await worker(new Request(`${ORIGIN}/v1/auth/device/token`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "192.0.2.18" },
      body: JSON.stringify({ device_code: code.device_code }),
    }), env);
    expect(exchanged.status).toBe(200);
    const headsetToken = (await exchanged.json() as { token: string }).token;
    const account = await worker(authedRequest(`${ORIGIN}/v1/account`, {}, headsetToken), env);
    expect((await account.json() as any).account).toMatchObject({
      tenantId: "apple-owner",
      ownerEmail: "apple-owner@example.com",
      identities: [{ provider: "apple" }, { provider: "horizon" }],
    });

    const returnLogin = await login(env, "proof-join-return-12345678");
    expect((await returnLogin.json() as any).status).toBe("signed_in");
  });

  it("refuses to bind a second Horizon user to one Apple account", async () => {
    const env = horizonEnv();
    verifiedMeta();
    await seedApiKey(env, "phone-app", "apple-owner", "app");
    await putAppleAccount(env, {
      appleSub: "apple-sub-1",
      tenantId: "apple-owner",
      email: "apple-owner@example.com",
    });

    for (const [userId, proof, expected] of [
      ["user-one", "proof-first-user-123", 200],
      ["user-two", "proof-second-user-123", 409],
    ] as const) {
      const link = await login(env, proof, "join_apple", userId);
      const code = await link.json() as { user_code: string };
      const approval = await worker(authedRequest(`${ORIGIN}/v1/auth/device/approve`, {
        method: "POST",
        body: JSON.stringify({ user_code: code.user_code }),
      }, "phone-app"), env);
      expect(approval.status).toBe(expected);
    }
  });
});
