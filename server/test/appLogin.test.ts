import { afterEach, describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import { __resetAppleJwksCache } from "../src/appleAuth";
import { RateLimitPolicies } from "../src/rateLimit";
import { makeEnv } from "./helpers";
import { listApiKeys } from "../src/auth";

const ctx = {} as ExecutionContext;

describe("app Apple login", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    __resetAppleJwksCache();
  });

  it("is disabled unless explicitly configured", async () => {
    const res = await (handler.fetch as any)(
      new Request("https://x/v1/auth/apple/token", {
        method: "POST",
        body: JSON.stringify({ identityToken: "x.y.z", nonce: TEST_RAW_NONCE }),
      }),
      makeEnv(),
      ctx,
    );
    expect(res.status).toBe(404);
  });

  it("exchanges a valid Apple identity token for a tenant API token", async () => {
    const clientId = "com.example.zerozerowidget";
    const { token, jwk } = await makeAppleIdToken({
      aud: clientId,
      email: "Customer@Example.com",
      nonce: await sha256HexTest(TEST_RAW_NONCE),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ keys: [jwk] }), { status: 200 })),
    );

    const env = makeEnv({
      APPLE_APP_LOGIN_ENABLED: "true",
      APPLE_APP_SIGN_IN_CLIENT_ID: clientId,
    });
    const res = await (handler.fetch as any)(
      new Request("https://x/v1/auth/apple/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          identityToken: token,
          nonce: TEST_RAW_NONCE,
          label: "Alice iPhone",
        }),
      }),
      env,
      ctx,
    );

    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      token: string;
      tenant: { ownerEmail: string };
      apiKey: { label: string; tokenHash: string };
      appCredential: string;
      publisherCredential: string;
    };
    expect(body.token).toMatch(/^zw_/);
    expect(body.tenant.ownerEmail).toBe("customer@example.com");
    expect(body.apiKey.label).toBe("Alice iPhone");
    expect(body.apiKey.tokenHash).not.toBe(body.token);
    expect(body.appCredential).toMatch(/^zwa_/);
    expect(body.publisherCredential).toMatch(/^zw_/);

    const cards = await (handler.fetch as any)(
      new Request("https://x/v1/cards", {
        headers: { authorization: `Bearer ${body.token}` },
      }),
      env,
      ctx,
    );
    expect(cards.status).toBe(200);

    const appCredentialCards = await (handler.fetch as any)(
      new Request("https://x/v1/cards", {
        headers: { authorization: `Bearer ${body.appCredential}` },
      }),
      env,
      ctx,
    );
    expect(appCredentialCards.status).toBe(403);

    const publisherCards = await (handler.fetch as any)(
      new Request("https://x/v1/cards", {
        headers: { authorization: `Bearer ${body.publisherCredential}` },
      }),
      env,
      ctx,
    );
    expect(publisherCards.status).toBe(200);

    const publisherDeviceRegistration = await (handler.fetch as any)(
      new Request("https://x/v1/devices/register", {
        method: "POST",
        headers: {
          authorization: `Bearer ${body.publisherCredential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ deviceId: "publisher-device", appVersion: "1.0" }),
      }),
      env,
      ctx,
    );
    expect(publisherDeviceRegistration.status).toBe(403);

    const devicePublish = await (handler.fetch as any)(
      new Request("https://x/v1/cards/upsert", {
        method: "POST",
        headers: {
          authorization: `Bearer ${body.token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ id: "forbidden", template: "summary", title: "No" }),
      }),
      env,
      ctx,
    );
    expect(devicePublish.status).toBe(403);

    expect(
      (await listApiKeys(env))
        .filter((key) => key.sessionId)
        .map((key) => key.scopes),
    ).toEqual(expect.arrayContaining([
      ["tenant:read", "publish"],
      ["tenant:read", "device:register", "actions:run"],
      ["actions:confirm", "shares:manage"],
    ]));
  });

  it("uses the stored Apple account mapping when a later token omits email", async () => {
    const clientId = "com.example.zerozerowidget";
    const keyPair = await makeAppleKeyPair();
    const nonceHash = await sha256HexTest(TEST_RAW_NONCE);
    const first = await makeAppleIdToken({
      aud: clientId,
      email: "customer@example.com",
      sub: "same-apple-user",
      nonce: nonceHash,
    }, keyPair);
    const second = await makeAppleIdToken({
      aud: clientId,
      sub: "same-apple-user",
      nonce: nonceHash,
    }, keyPair);
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ keys: [first.jwk] }), { status: 200 })),
    );

    const env = makeEnv({
      APPLE_APP_LOGIN_ENABLED: "true",
      APPLE_APP_SIGN_IN_CLIENT_ID: clientId,
    });
    const firstRes = await (handler.fetch as any)(
      new Request("https://x/v1/auth/apple/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: first.token, nonce: TEST_RAW_NONCE }),
      }),
      env,
      ctx,
    );
    expect(firstRes.status).toBe(201);
    const firstBody = (await firstRes.json()) as { tenant: { id: string } };

    const secondRes = await (handler.fetch as any)(
      new Request("https://x/v1/auth/apple/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: second.token, nonce: TEST_RAW_NONCE }),
      }),
      env,
      ctx,
    );
    expect(secondRes.status).toBe(201);
    const secondBody = (await secondRes.json()) as { tenant: { id: string; ownerEmail: string } };
    expect(secondBody.tenant.id).toBe(firstBody.tenant.id);
    expect(secondBody.tenant.ownerEmail).toBe("customer@example.com");
  });

  it("reuses an existing tenant with the same owner email on first Apple login", async () => {
    const clientId = "com.example.zerozerowidget";
    const { token, jwk } = await makeAppleIdToken({
      aud: clientId,
      email: "test-tenant@example.com",
      sub: "new-apple-user",
      nonce: await sha256HexTest(TEST_RAW_NONCE),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ keys: [jwk] }), { status: 200 })),
    );

    const env = makeEnv({
      APPLE_APP_LOGIN_ENABLED: "true",
      APPLE_APP_SIGN_IN_CLIENT_ID: clientId,
    });
    const res = await (handler.fetch as any)(
      new Request("https://x/v1/auth/apple/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: token, nonce: TEST_RAW_NONCE }),
      }),
      env,
      ctx,
    );

    expect(res.status).toBe(201);
    const body = (await res.json()) as { tenant: { id: string; ownerEmail: string } };
    expect(body.tenant.id).toBe("test-tenant");
    expect(body.tenant.ownerEmail).toBe("test-tenant@example.com");
  });

  it("rejects Apple tokens with unverified email", async () => {
    const clientId = "com.example.zerozerowidget";
    const { token, jwk } = await makeAppleIdToken({
      aud: clientId,
      email: "customer@example.com",
      emailVerified: false,
      nonce: await sha256HexTest(TEST_RAW_NONCE),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ keys: [jwk] }), { status: 200 })),
    );

    const res = await (handler.fetch as any)(
      new Request("https://x/v1/auth/apple/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: token, nonce: TEST_RAW_NONCE }),
      }),
      makeEnv({
        APPLE_APP_LOGIN_ENABLED: "true",
        APPLE_APP_SIGN_IN_CLIENT_ID: clientId,
      }),
      ctx,
    );

    expect(res.status).toBe(403);
    expect(await res.text()).toContain("Apple email is not verified");
  });


  it("rejects tokens for the wrong app audience", async () => {
    const { token, jwk } = await makeAppleIdToken({
      aud: "com.example.other",
      email: "customer@example.com",
      nonce: await sha256HexTest(TEST_RAW_NONCE),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ keys: [jwk] }), { status: 200 })),
    );

    const res = await (handler.fetch as any)(
      new Request("https://x/v1/auth/apple/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: token, nonce: TEST_RAW_NONCE }),
      }),
      makeEnv({
        APPLE_APP_LOGIN_ENABLED: "true",
        APPLE_APP_SIGN_IN_CLIENT_ID: "com.example.zerozerowidget",
      }),
      ctx,
    );
    expect(res.status).toBe(401);
    expect(await res.text()).toContain("bad aud");
  });

  it("rejects requests with no nonce", async () => {
    const clientId = "com.example.zerozerowidget";
    const { token, jwk } = await makeAppleIdToken({
      aud: clientId,
      email: "customer@example.com",
      nonce: await sha256HexTest(TEST_RAW_NONCE),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ keys: [jwk] }), { status: 200 })),
    );

    const res = await (handler.fetch as any)(
      new Request("https://x/v1/auth/apple/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: token }),
      }),
      makeEnv({
        APPLE_APP_LOGIN_ENABLED: "true",
        APPLE_APP_SIGN_IN_CLIENT_ID: clientId,
      }),
      ctx,
    );
    expect(res.status).toBe(400);
    expect(await res.text()).toContain("nonce is required");
  });

  it("rejects tokens whose nonce claim doesn't match the supplied nonce", async () => {
    const clientId = "com.example.zerozerowidget";
    const { token, jwk } = await makeAppleIdToken({
      aud: clientId,
      email: "customer@example.com",
      nonce: await sha256HexTest("a-different-raw-nonce-than-the-client"),
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ keys: [jwk] }), { status: 200 })),
    );

    const res = await (handler.fetch as any)(
      new Request("https://x/v1/auth/apple/token", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: token, nonce: TEST_RAW_NONCE }),
      }),
      makeEnv({
        APPLE_APP_LOGIN_ENABLED: "true",
        APPLE_APP_SIGN_IN_CLIENT_ID: clientId,
      }),
      ctx,
    );
    expect(res.status).toBe(401);
    expect(await res.text()).toContain("nonce mismatch");
  });

  it("rate-limits invalid tokens by IP before Apple verification", async () => {
    const env = makeEnv({
      APPLE_APP_LOGIN_ENABLED: "true",
      APPLE_APP_SIGN_IN_CLIENT_ID: "com.example.zerozerowidget",
    });
    const request = () => new Request("https://x/v1/auth/apple/token", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "cf-connecting-ip": "203.0.113.10",
      },
      body: JSON.stringify({ identityToken: "invalid.token.value", nonce: TEST_RAW_NONCE }),
    });

    for (let attempt = 0; attempt < RateLimitPolicies.appleLoginIpHour.limit; attempt += 1) {
      const response = await (handler.fetch as any)(request(), env, ctx);
      expect(response.status).toBe(401);
    }

    const limited = await (handler.fetch as any)(request(), env, ctx);
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).not.toBeNull();
    expect(await limited.text()).toContain("Apple login attempts per IP");
  });
});

// 32 chars so it clears the server-side min-length floor.
const TEST_RAW_NONCE = "test-raw-nonce-abcdef0123456789x";

async function sha256HexTest(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function makeAppleIdToken(input: { aud: string; email?: string; sub?: string; emailVerified?: boolean | string; nonce?: string }, keyPair?: CryptoKeyPair): Promise<{
  token: string;
  jwk: JsonWebKey;
}> {
  const kid = "test-kid";
  const pair = keyPair ?? await makeAppleKeyPair();
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey & {
    kid?: string;
    alg?: string;
    use?: string;
  };
  jwk.kid = kid;
  jwk.alg = "RS256";
  jwk.use = "sig";

  const now = Math.floor(Date.now() / 1000);
  const header = b64urlJson({ alg: "RS256", kid });
  const claims: Record<string, unknown> = {
    iss: "https://appleid.apple.com",
    aud: input.aud,
    exp: now + 300,
    iat: now,
    sub: input.sub ?? "apple-user-id",
  };
  if (input.nonce !== undefined) claims.nonce = input.nonce;
  if (input.email) {
    claims.email = input.email;
    claims.email_verified = input.emailVerified ?? true;
  }
  const payload = b64urlJson(claims);
  const data = new TextEncoder().encode(`${header}.${payload}`);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, data);
  return { token: `${header}.${payload}.${b64urlBytes(new Uint8Array(signature))}`, jwk };
}

async function makeAppleKeyPair(): Promise<CryptoKeyPair> {
  return (await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
}

function b64urlJson(value: unknown): string {
  return b64urlBytes(new TextEncoder().encode(JSON.stringify(value)));
}

function b64urlBytes(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
