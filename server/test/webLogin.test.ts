import { afterEach, describe, it, expect, vi } from "vitest";
import handler from "../src/index";
import { __resetAppleJwksCache } from "../src/appleAuth";
import { readSessionCookie } from "../src/webSession";
import type { Env } from "../src/types";
import { makeAppleIdToken, makeEnv, seedApiKey, TEST_API_KEY } from "./helpers";

const ctx = {} as ExecutionContext;
const ORIGIN = "https://api.example.com";
const SESSION_SECRET = "test-session-secret-0123456789abcdef";
const CLIENT_ID = "com.example.zerozerowidget.signin";

function fetchWorker(req: Request, env: Env, executionCtx: ExecutionContext): Promise<Response> {
  return (handler.fetch as (r: Request, e: Env, c: ExecutionContext) => Promise<Response>)(
    req,
    env,
    executionCtx,
  );
}

afterEach(() => {
  vi.restoreAllMocks();
  __resetAppleJwksCache();
});

function webEnv(overrides: Partial<Env> = {}): Env {
  return makeEnv({
    APPLE_SIGN_IN_CLIENT_ID: CLIENT_ID,
    APPLE_SIGN_IN_REDIRECT_URI: `${ORIGIN}/auth/apple/callback`,
    ADMIN_EMAILS: "admin@example.com",
    SESSION_SECRET,
    ...overrides,
  });
}

/// Drives the real callback with a genuine, correctly signed Apple id_token.
async function signIn(
  env: Env,
  input: { email: string; sub?: string; next?: string },
): Promise<Response> {
  const nonce = "expected-nonce-value";
  // Each call mints a fresh key pair, so the JWKS cached from a previous
  // sign-in in the same test would reject the new signature.
  __resetAppleJwksCache();
  const { token, jwk } = await makeAppleIdToken({
    aud: CLIENT_ID,
    email: input.email,
    emailVerified: true,
    nonce,
    sub: input.sub ?? `sub-${input.email}`,
  });
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(JSON.stringify({ keys: [jwk] }), { status: 200 })),
  );
  const cookies = [`zw_state=expected`, `zw_nonce=${nonce}`];
  if (input.next) cookies.push(`zw_next=${encodeURIComponent(input.next)}`);
  return fetchWorker(
    new Request(`${ORIGIN}/auth/apple/callback`, {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        "cf-connecting-ip": "203.0.113.20",
        cookie: cookies.join("; "),
      },
      body: new URLSearchParams({ state: "expected", id_token: token }).toString(),
    }),
    env,
    ctx,
  );
}

function sessionCookieFrom(res: Response): string | undefined {
  return res.headers
    .getSetCookie()
    .map((value) => value.split(";")[0])
    .find((value) => value.startsWith("zw_session="));
}

async function tenantCount(env: Env): Promise<number> {
  const rows = await env.ZW_DB.prepare(
    `SELECT id, owner_email, created_at, disabled_at FROM tenants ORDER BY created_at DESC, owner_email`,
  ).all();
  return rows.results.length;
}

describe("signing in does not sign you up", () => {
  it("turns away an Apple identity with no account, and creates nothing", async () => {
    const env = webEnv();
    await seedApiKey(env, TEST_API_KEY, "existing-tenant");
    const before = await tenantCount(env);

    const res = await signIn(env, { email: "stranger@example.com" });

    expect(res.status).toBe(403);
    expect(await res.text()).toContain("Accounts are created in the iOS app");
    expect(sessionCookieFrom(res)).toBeUndefined();
    expect(await tenantCount(env)).toBe(before);
  });

  it("signs in someone who already has an account from the app", async () => {
    const env = webEnv();
    // seedApiKey gives the tenant `<id>@example.com` as its owner.
    await seedApiKey(env, TEST_API_KEY, "known");
    const before = await tenantCount(env);

    const res = await signIn(env, { email: "known@example.com" });

    expect(res.status).toBe(302);
    expect(sessionCookieFrom(res)).toBeDefined();
    // Signing in must not fork a second tenant for a person who has one.
    expect(await tenantCount(env)).toBe(before);
  });

  it("creates the account when the operator has opted in to web signup", async () => {
    const env = webEnv({ WEB_SIGNUP_ENABLED: "true" });
    const before = await tenantCount(env);

    const res = await signIn(env, { email: "newcomer@example.com" });

    expect(res.status).toBe(302);
    expect(sessionCookieFrom(res)).toBeDefined();
    expect(await tenantCount(env)).toBe(before + 1);
  });

  it("lets an administrator in even with no tenant of their own", async () => {
    const env = webEnv();
    const before = await tenantCount(env);

    const res = await signIn(env, { email: "admin@example.com" });

    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/admin");
    expect(sessionCookieFrom(res)).toBeDefined();
    // Admin capability is not an account: nothing was provisioned for them.
    expect(await tenantCount(env)).toBe(before);
  });

  it("matches an account by Apple's subject id, not only by email", async () => {
    const env = webEnv();
    await seedApiKey(env, TEST_API_KEY, "known");
    // First sign-in resolves by email and binds the subject.
    await signIn(env, { email: "known@example.com", sub: "apple-sub-1" });

    // The address later changes — a relay address, or an Apple ID edit. The
    // subject is what carries the account forward.
    const res = await signIn(env, { email: "moved@example.com", sub: "apple-sub-1" });
    expect(res.status).toBe(302);
    expect(sessionCookieFrom(res)).toBeDefined();
  });
});

describe("web session versus admin capability", () => {
  it("gives an ordinary user a session that is not an admin session", async () => {
    const env = webEnv();
    await seedApiKey(env, TEST_API_KEY, "known");
    const res = await signIn(env, { email: "known@example.com" });
    const cookie = sessionCookieFrom(res)!;

    const session = await readSessionCookie(env, new Request(`${ORIGIN}/`, { headers: { cookie } }));
    expect(session?.email).toBe("known@example.com");
    expect(session?.isAdmin).toBe(false);

    const dashboard = await fetchWorker(
      new Request(`${ORIGIN}/admin`, { headers: { cookie } }),
      env,
      ctx,
    );
    expect(dashboard.status).toBe(403);
    expect(await dashboard.text()).toContain("not an administrator");
  });

  it("refuses an admin mutation from an ordinary session, not just the dashboard view", async () => {
    const env = webEnv();
    await seedApiKey(env, TEST_API_KEY, "known");
    const res = await signIn(env, { email: "known@example.com" });
    const cookie = sessionCookieFrom(res)!;
    const session = await readSessionCookie(env, new Request(`${ORIGIN}/`, { headers: { cookie } }));

    // A valid session with a valid CSRF token for that session — everything a
    // legitimate request carries. The capability is the only thing missing.
    const created = await fetchWorker(
      new Request(`${ORIGIN}/admin/api-keys`, {
        method: "POST",
        headers: {
          cookie,
          origin: ORIGIN,
          "content-type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({
          csrf: session!.csrf,
          ownerEmail: "victim@example.com",
          preset: "producer",
        }).toString(),
      }),
      env,
      ctx,
    );
    expect(created.status).toBe(403);
    expect(await created.text()).toContain("not an administrator");
  });

  it("sends an ordinary user to the site root, not the dashboard", async () => {
    const env = webEnv();
    await seedApiKey(env, TEST_API_KEY, "known");
    const res = await signIn(env, { email: "known@example.com" });
    expect(res.headers.get("location")).toBe("/");
  });

  it("returns to where the person was headed", async () => {
    const env = webEnv();
    await seedApiKey(env, TEST_API_KEY, "known");
    const res = await signIn(env, {
      email: "known@example.com",
      next: "/connect/mcp/authorize?client_id=zwc_x",
    });
    expect(res.headers.get("location")).toBe("/connect/mcp/authorize?client_id=zwc_x");
  });

  it("refuses to bounce anywhere outside the web surface", async () => {
    const env = webEnv();
    await seedApiKey(env, TEST_API_KEY, "known");
    for (const next of ["https://evil.example.com", "//evil.example.com", "/v1/cards", "/"]) {
      const res = await signIn(env, { email: "known@example.com", next });
      expect(res.headers.get("location"), next).toBe("/");
    }
  });
});

describe("web sign-in surface", () => {
  it("serves the sign-in page at /login", async () => {
    const res = await fetchWorker(new Request(`${ORIGIN}/login`), webEnv(), ctx);
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain("Sign in with Apple");
    // It is not framed as an admin console: most people signing in are not.
    expect(body).not.toContain("Admin</h1>");
  });

  it("sends the browser to Apple with a state and nonce", async () => {
    const res = await fetchWorker(new Request(`${ORIGIN}/login/apple`), webEnv(), ctx);
    expect(res.status).toBe(302);
    const location = new URL(res.headers.get("location")!);
    expect(location.origin).toBe("https://appleid.apple.com");
    expect(location.searchParams.get("client_id")).toBe(CLIENT_ID);
    expect(location.searchParams.get("response_mode")).toBe("form_post");
    const cookies = res.headers.getSetCookie().join("; ");
    expect(cookies).toContain("zw_state=");
    expect(cookies).toContain("zw_nonce=");
  });

  it("never sends a referrer policy that would null out its own form POSTs", async () => {
    const env = webEnv();
    // Every page carrying a form the CSRF origin check guards. "no-referrer"
    // strips both Origin and Referer from a navigate-mode POST, which is
    // exactly the pair `sameOriginRequest` reads.
    for (const path of ["/login", "/admin"]) {
      const res = await fetchWorker(new Request(`${ORIGIN}${path}`), env, ctx);
      expect(res.headers.get("referrer-policy"), path).not.toBe("no-referrer");
    }
  });

  it("clears the session at /logout", async () => {
    const res = await fetchWorker(new Request(`${ORIGIN}/logout`), webEnv(), ctx);
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/login");
    expect(res.headers.getSetCookie().join("; ")).toContain("zw_session=;");
  });

  it("scopes the session cookie to the whole site, since the web surface is not one directory", async () => {
    const env = webEnv();
    await seedApiKey(env, TEST_API_KEY, "known");
    const res = await signIn(env, { email: "known@example.com" });
    const raw = res.headers.getSetCookie().find((value) => value.startsWith("zw_session="))!;
    expect(raw).toContain("Path=/");
    expect(raw).toContain("HttpOnly");
    expect(raw).toContain("SameSite=Lax");
  });
});
