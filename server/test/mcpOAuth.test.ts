import { describe, it, expect, afterEach, vi } from "vitest";
import handler from "../src/index";
import { makeSessionCookie, readSessionCookie } from "../src/webSession";
import type { Env } from "../src/types";
import * as storage from "../src/storage";
import { makeEnv, seedApiKey, TEST_API_KEY } from "./helpers";

const ctx = {} as ExecutionContext;

// `handler.fetch` is typed for a real edge request; these are plain ones.
function fetchWorker(req: Request, env: Env, executionCtx: ExecutionContext): Promise<Response> {
  return (handler.fetch as (r: Request, e: Env, c: ExecutionContext) => Promise<Response>)(
    req,
    env,
    executionCtx,
  );
}

const ORIGIN = "https://api.example.com";
const SESSION_SECRET = "test-session-secret-0123456789abcdef";
const REDIRECT_URI = "https://chatgpt.com/connector_platform_oauth_redirect";
const VERIFIER = "verifier-0123456789-0123456789-0123456789-abcdef";

afterEach(() => {
  vi.useRealTimers();
});

function oauthEnv(overrides: Partial<Env> = {}): Env {
  return makeEnv({
    MCP_ENABLED: "true",
    SESSION_SECRET,
    APPLE_SIGN_IN_CLIENT_ID: "com.example.zerozerowidget.signin",
    APPLE_SIGN_IN_REDIRECT_URI: `${ORIGIN}/auth/apple/callback`,
    ADMIN_EMAILS: "admin@example.com",
    ...overrides,
  });
}

// The tenant `seedApiKey` creates owns this address, and it is deliberately not
// in ADMIN_EMAILS: connecting a client is something any signed-in person may do
// for their own account.
const OWNER_EMAIL = "test-tenant@example.com";

async function webSession(
  env: Env,
  email = OWNER_EMAIL,
): Promise<{ cookie: string; csrf: string }> {
  const cookie = (await makeSessionCookie(env, email)).split(";")[0];
  const session = await readSessionCookie(env, new Request(`${ORIGIN}/`, { headers: { cookie } }));
  if (!session?.csrf) throw new Error("test session has no csrf token");
  return { cookie, csrf: session.csrf };
}

async function pkceChallenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function registerClient(env: Env, body: unknown = {
  client_name: "ChatGPT",
  redirect_uris: [REDIRECT_URI],
}): Promise<Response> {
  return fetchWorker(
    new Request(`${ORIGIN}/oauth/register`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
    env,
    ctx,
  );
}

async function authorizeQuery(clientId: string, overrides: Record<string, string> = {}): Promise<string> {
  const params = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: REDIRECT_URI,
    code_challenge: await pkceChallenge(VERIFIER),
    code_challenge_method: "S256",
    state: "xyz",
    ...overrides,
  });
  return params.toString();
}

async function approve(env: Env, clientId: string, overrides: Record<string, string> = {}): Promise<Response> {
  const { cookie, csrf } = await webSession(env);
  const body = new URLSearchParams(await authorizeQuery(clientId, overrides));
  body.set("decision", "approve");
  body.set("csrf", csrf);
  return fetchWorker(
    new Request(`${ORIGIN}/connect/mcp/authorize`, {
      method: "POST",
      headers: {
        cookie,
        origin: ORIGIN,
        "content-type": "application/x-www-form-urlencoded",
      },
      body: body.toString(),
    }),
    env,
    ctx,
  );
}

async function exchange(env: Env, params: Record<string, string>): Promise<Response> {
  return fetchWorker(
    new Request(`${ORIGIN}/oauth/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(params).toString(),
    }),
    env,
    ctx,
  );
}

/// Registers, approves and redeems in one go — the happy path most tests need
/// as a precondition rather than as their subject.
async function connect(env: Env): Promise<{ token: string; clientId: string }> {
  const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
  const approved = await approve(env, clientId);
  const code = new URL(approved.headers.get("location")!).searchParams.get("code")!;
  const token = (await (
    await exchange(env, {
      grant_type: "authorization_code",
      code,
      client_id: clientId,
      redirect_uri: REDIRECT_URI,
      code_verifier: VERIFIER,
    })
  ).json()) as { access_token: string };
  return { token: token.access_token, clientId };
}

describe("OAuth discovery documents", () => {
  it("describes the resource from the host it was fetched on", async () => {
    const res = await fetchWorker(
      new Request("https://staging.example.org/.well-known/oauth-protected-resource"),
      oauthEnv(),
      ctx,
    );
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.resource).toBe("https://staging.example.org/mcp");
    expect(body.authorization_servers).toEqual(["https://staging.example.org"]);
  });

  it("is also served at the resource-suffixed path RFC 9728 allows", async () => {
    const res = await fetchWorker(
      new Request(`${ORIGIN}/.well-known/oauth-protected-resource/mcp`),
      oauthEnv(),
      ctx,
    );
    expect(res.status).toBe(200);
  });

  it("advertises PKCE-only, public-client authorization", async () => {
    const res = await fetchWorker(
      new Request(`${ORIGIN}/.well-known/oauth-authorization-server`),
      oauthEnv(),
      ctx,
    );
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.issuer).toBe(ORIGIN);
    expect(body.authorization_endpoint).toBe(`${ORIGIN}/connect/mcp/authorize`);
    expect(body.token_endpoint).toBe(`${ORIGIN}/oauth/token`);
    expect(body.code_challenge_methods_supported).toEqual(["S256"]);
    expect(body.token_endpoint_auth_methods_supported).toEqual(["none"]);
  });

  it("404s both documents when MCP is disabled", async () => {
    for (const path of ["/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server"]) {
      const res = await fetchWorker(new Request(`${ORIGIN}${path}`), makeEnv(), ctx);
      expect(res.status).toBe(404);
    }
  });
});

describe("dynamic client registration", () => {
  it("issues a signed client id without storing anything", async () => {
    const res = await registerClient(oauthEnv());
    expect(res.status).toBe(201);
    const body = (await res.json()) as { client_id: string; token_endpoint_auth_method: string };
    expect(body.client_id.startsWith("zwc_")).toBe(true);
    expect(body.token_endpoint_auth_method).toBe("none");
  });

  it("rejects a non-loopback http redirect", async () => {
    const res = await registerClient(oauthEnv(), {
      client_name: "Sketchy",
      redirect_uris: ["http://evil.example.com/cb"],
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toBe("invalid_redirect_uri");
  });

  it("accepts a loopback http redirect, which is how local clients receive the code", async () => {
    const res = await registerClient(oauthEnv(), {
      client_name: "Local",
      redirect_uris: ["http://localhost:5173/callback"],
    });
    expect(res.status).toBe(201);
  });

  it("rejects a redirect carrying a fragment, which would swallow the code", async () => {
    const res = await registerClient(oauthEnv(), {
      client_name: "Fragmented",
      redirect_uris: ["https://example.com/cb#token"],
    });
    expect(res.status).toBe(400);
  });

  it("requires at least one redirect uri", async () => {
    const res = await registerClient(oauthEnv(), { client_name: "None", redirect_uris: [] });
    expect(res.status).toBe(400);
  });
});

describe("authorization", () => {
  it("sends an unauthenticated operator to sign in, and comes back to the same request", async () => {
    const env = oauthEnv();
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const query = await authorizeQuery(clientId);
    const res = await fetchWorker(new Request(`${ORIGIN}/connect/mcp/authorize?${query}`), env, ctx);
    expect(res.status).toBe(302);
    const location = res.headers.get("location")!;
    expect(location.startsWith("/login?next=")).toBe(true);
    expect(decodeURIComponent(location.split("next=")[1])).toContain("/connect/mcp/authorize?");
  });

  it("shows the consent screen to a signed-in operator", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const { cookie } = await webSession(env);
    const res = await fetchWorker(
      new Request(`${ORIGIN}/connect/mcp/authorize?${await authorizeQuery(clientId)}`, { headers: { cookie } }),
      env,
      ctx,
    );
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("ChatGPT can <strong>read</strong> your cards and activities and");
    expect(html).toContain("<strong>publish</strong> to them.");
    expect(html).not.toContain("<th>Client</th>");
    expect(html).not.toContain("<th>Account</th>");
    expect(html).not.toContain("<th>Scopes</th>");
    expect(html).toContain('<span class="oauth-detail-label">Redirects to</span>');
    expect(html).toContain(`<code>${REDIRECT_URI}</code>`);
    expect(html).not.toContain("It cannot register devices");
    expect(html).toContain('<p class="actions">');
    expect(html).toContain('<button class="button button-secondary" type="submit" name="decision" value="deny">');
    expect(html).toContain('<button class="button" type="submit" name="decision" value="approve">');
    expect(html.indexOf('value="deny"')).toBeLessThan(html.indexOf('value="approve"'));
    // The redirect target has to be listed, or the browser may refuse the
    // 303 the approval answers with.
    expect(res.headers.get("content-security-policy")).toContain("form-action 'self' https://chatgpt.com");
    // The Approve button is a form POST, and "no-referrer" would null its
    // Origin header and drop Referer, so the CSRF check would reject it.
    expect(res.headers.get("referrer-policy")).toBe("same-origin");
  });

  it("refuses a redirect_uri the client never registered", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const { cookie } = await webSession(env);
    const query = await authorizeQuery(clientId, { redirect_uri: "https://chatgpt.com.evil.test/cb" });
    const res = await fetchWorker(
      new Request(`${ORIGIN}/connect/mcp/authorize?${query}`, { headers: { cookie } }),
      env,
      ctx,
    );
    expect(res.status).toBe(400);
    expect(await res.text()).toContain("redirect_uri");
  });

  it("requires PKCE with S256", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const { cookie } = await webSession(env);
    const broken: Record<string, string>[] = [{ code_challenge: "" }, { code_challenge_method: "plain" }];
    for (const overrides of broken) {
      const query = await authorizeQuery(clientId, overrides);
      const res = await fetchWorker(
        new Request(`${ORIGIN}/connect/mcp/authorize?${query}`, { headers: { cookie } }),
        env,
        ctx,
      );
      expect(res.status).toBe(400);
    }
  });

  it("rejects a forged client id", async () => {
    const env = oauthEnv();
    const { cookie } = await webSession(env);
    const query = await authorizeQuery("zwc_eyJuIjoiRXZpbCJ9.deadbeef");
    const res = await fetchWorker(
      new Request(`${ORIGIN}/connect/mcp/authorize?${query}`, { headers: { cookie } }),
      env,
      ctx,
    );
    expect(res.status).toBe(400);
  });

  it("returns the code and the client's state on approval", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const res = await approve(env, clientId);
    expect(res.status).toBe(303);
    const location = new URL(res.headers.get("location")!);
    expect(location.origin + location.pathname).toBe(REDIRECT_URI);
    expect(location.searchParams.get("state")).toBe("xyz");
    expect(location.searchParams.get("code")).toBeTruthy();
  });

  it("reports a denial to the client rather than issuing a code", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const { cookie, csrf } = await webSession(env);
    const body = new URLSearchParams(await authorizeQuery(clientId));
    body.set("decision", "deny");
    body.set("csrf", csrf);
    const res = await fetchWorker(
      new Request(`${ORIGIN}/connect/mcp/authorize`, {
        method: "POST",
        headers: { cookie, origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" },
        body: body.toString(),
      }),
      env,
      ctx,
    );
    const location = new URL(res.headers.get("location")!);
    expect(location.searchParams.get("error")).toBe("access_denied");
    expect(location.searchParams.get("code")).toBeNull();
  });

  it("refuses an approval without the admin CSRF token", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const { cookie } = await webSession(env);
    const body = new URLSearchParams(await authorizeQuery(clientId));
    body.set("decision", "approve");
    const res = await fetchWorker(
      new Request(`${ORIGIN}/connect/mcp/authorize`, {
        method: "POST",
        headers: { cookie, origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" },
        body: body.toString(),
      }),
      env,
      ctx,
    );
    expect(res.status).toBe(403);
  });

  it("refuses to connect anything when the signed-in person owns no tenant", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const { cookie } = await webSession(env, "stranger@example.com");
    const res = await fetchWorker(
      new Request(`${ORIGIN}/connect/mcp/authorize?${await authorizeQuery(clientId)}`, {
        headers: { cookie },
      }),
      env,
      ctx,
    );
    expect(res.status).toBe(409);
    expect(await res.text()).toContain("does not own a 00Widget account");
  });

  it("ignores a tenant id planted in the approval form", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    await seedApiKey(env, "victim", "victim-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const { cookie, csrf } = await webSession(env);
    const body = new URLSearchParams(await authorizeQuery(clientId));
    body.set("decision", "approve");
    body.set("csrf", csrf);
    body.set("tenantId", "victim-tenant");

    const approved = await fetchWorker(
      new Request(`${ORIGIN}/connect/mcp/authorize`, {
        method: "POST",
        headers: { cookie, origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" },
        body: body.toString(),
      }),
      env,
      ctx,
    );
    const code = new URL(approved.headers.get("location")!).searchParams.get("code")!;
    const token = ((await (
      await exchange(env, {
        grant_type: "authorization_code",
        code,
        client_id: clientId,
        redirect_uri: REDIRECT_URI,
        code_verifier: VERIFIER,
      })
    ).json()) as { access_token: string }).access_token;

    // Publishing with the minted credential lands in the approver's tenant, not
    // the one the form named.
    await fetchWorker(
      new Request(`${ORIGIN}/v1/cards/upsert`, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify({ id: "probe", template: "summary", title: "Probe" }),
      }),
      env,
      ctx,
    );
    expect(await storage.getCard(env, "test-tenant", "probe")).toBeTruthy();
    expect(await storage.getCard(env, "victim-tenant", "probe")).toBeNull();
  });
});

describe("token exchange", () => {
  // A signed code cannot be marked used, so single-use once rested on the
  // 60-second lifetime plus PKCE. That makes a code inert to anyone without the
  // verifier and does nothing about the client that holds it — and every
  // redemption calls createApiKey.
  it("mints exactly one credential per authorization code", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const code = new URL((await approve(env, clientId)).headers.get("location")!).searchParams.get("code")!;
    const exchangeOnce = () => exchange(env, {
      grant_type: "authorization_code",
      code,
      client_id: clientId,
      redirect_uri: REDIRECT_URI,
      code_verifier: VERIFIER,
    });

    const first = await exchangeOnce();
    expect(first.status).toBe(200);

    const second = await exchangeOnce();
    expect(second.status).toBe(400);
    const body = (await second.json()) as { error: string; error_description: string };
    expect(body.error).toBe("invalid_grant");
    expect(body.error_description).toMatch(/already been redeemed/);
  });

  it("does not burn a code on an exchange that fails for another reason", async () => {
    // The claim is the last check, so a client that fumbles the verifier — or
    // races itself with a stale redirect_uri — can still complete the flow it
    // is in the middle of.
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const code = new URL((await approve(env, clientId)).headers.get("location")!).searchParams.get("code")!;

    const wrongVerifier = await exchange(env, {
      grant_type: "authorization_code",
      code,
      client_id: clientId,
      redirect_uri: REDIRECT_URI,
      code_verifier: "not-the-verifier-that-was-committed-to-at-authorize-time",
    });
    expect(wrongVerifier.status).toBe(400);

    const retry = await exchange(env, {
      grant_type: "authorization_code",
      code,
      client_id: clientId,
      redirect_uri: REDIRECT_URI,
      code_verifier: VERIFIER,
    });
    expect(retry.status).toBe(200);
  });

  it("gives every authorization code a distinct id", async () => {
    // Two codes for the same client and tenant must not collide, or approving
    // a second connector would look like a replay of the first.
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const codeOf = async () =>
      new URL((await approve(env, clientId)).headers.get("location")!).searchParams.get("code")!;

    const [a, b] = [await codeOf(), await codeOf()];
    const jti = (code: string) =>
      JSON.parse(Buffer.from(code.split(".")[0], "base64url").toString()).jti as string;

    expect(jti(a)).not.toBe(jti(b));
    expect(jti(a)).toBeTruthy();

    for (const code of [a, b]) {
      const res = await exchange(env, {
        grant_type: "authorization_code",
        code,
        client_id: clientId,
        redirect_uri: REDIRECT_URI,
        code_verifier: VERIFIER,
      });
      expect(res.status).toBe(200);
    }
  });

  it("mints a working producer credential", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const code = new URL((await approve(env, clientId)).headers.get("location")!).searchParams.get("code")!;

    const res = await exchange(env, {
      grant_type: "authorization_code",
      code,
      client_id: clientId,
      redirect_uri: REDIRECT_URI,
      code_verifier: VERIFIER,
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    const body = (await res.json()) as { access_token: string; token_type: string; scope: string };
    expect(body.token_type).toBe("Bearer");
    expect(body.access_token.startsWith("zw_")).toBe(true);
    // Publishing, and nothing that administers the account. `webhook:manage` is
    // deliberately absent: the webhook is a URL the operator runs and a signing
    // secret handed back once, neither of which belongs to a connector approved
    // in a browser.
    expect(body.scope.split(" ").sort()).toEqual(["publish", "read"]);

    // The point of the whole flow: the token is an ordinary API credential.
    const cards = await fetchWorker(
      new Request(`${ORIGIN}/v1/cards`, { headers: { authorization: `Bearer ${body.access_token}` } }),
      env,
      ctx,
    );
    expect(cards.status).toBe(200);
  });

  it("grants an MCP client no authority over devices, shares or confirmed actions", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const { token } = await connect(env);
    for (const path of ["/v1/devices/register", "/v1/shares"]) {
      const res = await fetchWorker(
        new Request(`${ORIGIN}${path}`, {
          method: "POST",
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          body: "{}",
        }),
        env,
        ctx,
      );
      expect(res.status, path).toBe(403);
    }
  });

  it("cannot read, change or rotate the account's action webhook", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const { token } = await connect(env);
    const attempts: Array<[string, RequestInit]> = [
      ["GET", {}],
      ["PUT", { body: JSON.stringify({ url: "https://example.com/hook" }) }],
      ["DELETE", {}],
      // The one that would actually matter: rotating hands back a new signing
      // secret, once.
      ["PUT", { body: JSON.stringify({ url: "https://example.com/hook", rotateSecret: true }) }],
    ];
    for (const [method, init] of attempts) {
      const res = await fetchWorker(
        new Request(`${ORIGIN}/v1/integrations/webhook`, {
          ...init,
          method,
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        }),
        env,
        ctx,
      );
      expect(res.status, method).toBe(403);
      expect(((await res.json()) as { error: string }).error).toContain("webhook:manage");
    }
  });

  it("does not advertise a scope it will not grant", async () => {
    const env = oauthEnv();
    for (const path of [
      "/.well-known/oauth-authorization-server",
      "/.well-known/oauth-protected-resource",
    ]) {
      const res = await fetchWorker(new Request(`${ORIGIN}${path}`), env, ctx);
      const body = (await res.json()) as { scopes_supported?: string[] };
      if (!body.scopes_supported) continue;
      expect(body.scopes_supported, path).not.toContain("webhook:manage");
    }
  });

  it("rejects a code redeemed with the wrong verifier", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const code = new URL((await approve(env, clientId)).headers.get("location")!).searchParams.get("code")!;
    const res = await exchange(env, {
      grant_type: "authorization_code",
      code,
      client_id: clientId,
      redirect_uri: REDIRECT_URI,
      code_verifier: `${VERIFIER}-wrong`,
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toBe("invalid_grant");
  });

  it("rejects a code presented by a different client", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const otherId = ((await (
      await registerClient(env, { client_name: "Other", redirect_uris: [REDIRECT_URI] })
    ).json()) as { client_id: string }).client_id;
    const code = new URL((await approve(env, clientId)).headers.get("location")!).searchParams.get("code")!;
    const res = await exchange(env, {
      grant_type: "authorization_code",
      code,
      client_id: otherId,
      redirect_uri: REDIRECT_URI,
      code_verifier: VERIFIER,
    });
    expect(res.status).toBe(400);
  });

  it("rejects a tampered code", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const code = new URL((await approve(env, clientId)).headers.get("location")!).searchParams.get("code")!;
    const [payload, sig] = code.split(".");
    const forged = `${payload.slice(0, -4)}AAAA.${sig}`;
    const res = await exchange(env, {
      grant_type: "authorization_code",
      code: forged,
      client_id: clientId,
      redirect_uri: REDIRECT_URI,
      code_verifier: VERIFIER,
    });
    expect(res.status).toBe(400);
  });

  it("rejects a code once its short window has passed", async () => {
    const env = oauthEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const clientId = ((await (await registerClient(env)).json()) as { client_id: string }).client_id;
    const code = new URL((await approve(env, clientId)).headers.get("location")!).searchParams.get("code")!;
    vi.useFakeTimers();
    vi.setSystemTime(new Date(Date.now() + 120_000));
    const res = await exchange(env, {
      grant_type: "authorization_code",
      code,
      client_id: clientId,
      redirect_uri: REDIRECT_URI,
      code_verifier: VERIFIER,
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error_description: string }).error_description).toContain("expired");
  });

  it("rejects a grant type it does not implement", async () => {
    const env = oauthEnv();
    const res = await exchange(env, { grant_type: "client_credentials", code: "x", client_id: "y" });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: string }).error).toBe("unsupported_grant_type");
  });
});

describe("sign-in return path", () => {
  it("only honours same-origin admin paths, so ?next= cannot become an open redirect", async () => {
    const env = oauthEnv();
    for (const next of ["https://evil.example.com", "//evil.example.com", "/v1/cards"]) {
      const res = await fetchWorker(
        new Request(`${ORIGIN}/login/apple?next=${encodeURIComponent(next)}`),
        env,
        ctx,
      );
      const cookies = res.headers.getSetCookie().join("; ");
      expect(cookies, next).not.toContain("zw_next=");
    }
  });

  it("carries a legitimate authorize URL through the Apple round trip", async () => {
    const env = oauthEnv();
    const next = "/connect/mcp/authorize?client_id=zwc_abc&response_type=code";
    const res = await fetchWorker(
      new Request(`${ORIGIN}/login/apple?next=${encodeURIComponent(next)}`),
      env,
      ctx,
    );
    const cookies = res.headers.getSetCookie().join("; ");
    expect(cookies).toContain("zw_next=");
  });
});
