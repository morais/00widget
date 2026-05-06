import { afterEach, describe, expect, it, vi } from "vitest";
import handler from "../src/index";
import { __resetAppleJwksCache } from "../src/appleAuth";
import { makeEnv } from "./helpers";

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
        body: JSON.stringify({ identityToken: "x.y.z" }),
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
        body: JSON.stringify({ identityToken: token, label: "Alice iPhone" }),
      }),
      env,
      ctx,
    );

    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      token: string;
      tenant: { ownerEmail: string };
      apiKey: { label: string; tokenHash: string };
    };
    expect(body.token).toMatch(/^zw_/);
    expect(body.tenant.ownerEmail).toBe("customer@example.com");
    expect(body.apiKey.label).toBe("Alice iPhone");
    expect(body.apiKey.tokenHash).not.toBe(body.token);

    const cards = await (handler.fetch as any)(
      new Request("https://x/v1/cards", {
        headers: { authorization: `Bearer ${body.token}` },
      }),
      env,
      ctx,
    );
    expect(cards.status).toBe(200);
  });

  it("uses the stored Apple account mapping when a later token omits email", async () => {
    const clientId = "com.example.zerozerowidget";
    const keyPair = await makeAppleKeyPair();
    const first = await makeAppleIdToken({
      aud: clientId,
      email: "customer@example.com",
      sub: "same-apple-user",
    }, keyPair);
    const second = await makeAppleIdToken({
      aud: clientId,
      sub: "same-apple-user",
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
        body: JSON.stringify({ identityToken: first.token }),
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
        body: JSON.stringify({ identityToken: second.token }),
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
        body: JSON.stringify({ identityToken: token }),
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

    expect(res.status).toBe(403);
    expect(await res.text()).toContain("Apple email is not verified");
  });


  it("rejects tokens for the wrong app audience", async () => {
    const { token, jwk } = await makeAppleIdToken({
      aud: "com.example.other",
      email: "customer@example.com",
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
        APPLE_APP_SIGN_IN_CLIENT_ID: "com.example.zerozerowidget",
      }),
      ctx,
    );
    expect(res.status).toBe(401);
    expect(await res.text()).toContain("bad aud");
  });
});

async function makeAppleIdToken(input: { aud: string; email?: string; sub?: string; emailVerified?: boolean | string }, keyPair?: CryptoKeyPair): Promise<{
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
