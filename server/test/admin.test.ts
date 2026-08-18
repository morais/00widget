import { afterEach, describe, it, expect, vi } from "vitest";
import handler from "../src/index";
import { randomToken, __resetAppleJwksCache } from "../src/appleAuth";
import {
  adminAccessConfigured,
  isAdminEmail,
  makeSessionCookie,
  readSessionCookie,
  webSignInConfigured,
} from "../src/webSession";
import { authedRequest, makeAppleIdToken, makeEnv, seedApiKey } from "./helpers";

const ctx = {} as ExecutionContext;
const TEST_ADMIN_TOKEN = "test-admin-token-0123456789abcdef";
const OTHER_ADMIN_TOKEN = "other-admin-token-0123456789abcdef";
const NEW_ADMIN_TOKEN = "new-admin-token-0123456789abcdefgh";
const TEST_SESSION_SECRET = "test-session-secret-0123456789abcdef";

afterEach(() => {
  vi.restoreAllMocks();
  __resetAppleJwksCache();
});

function adminEnv(overrides = {}) {
  return makeEnv({
    APPLE_SIGN_IN_CLIENT_ID: "com.example.zerozerowidget.signin",
    APPLE_SIGN_IN_REDIRECT_URI: "https://example.com/auth/apple/callback",
    ADMIN_EMAILS: "admin@example.com,Other@Example.com",
    SESSION_SECRET: TEST_SESSION_SECRET,
    API_KEYS: TEST_ADMIN_TOKEN,
    ADMIN_API_TOKEN_LOGIN: "true",
    ...overrides,
  });
}

async function adminCookie(env: ReturnType<typeof adminEnv>): Promise<{ cookie: string; csrf: string }> {
  const cookie = (await makeSessionCookie(env, "admin@example.com")).split(";")[0];
  const session = await readSessionCookie(env, new Request("https://x/admin", { headers: { cookie } }));
  if (!session?.csrf) throw new Error("test admin session missing csrf");
  return { cookie, csrf: session.csrf };
}

describe("webSignInConfigured", () => {
  it("is false when any required env is missing", () => {
    expect(webSignInConfigured(makeEnv())).toBe(false);
    expect(webSignInConfigured(adminEnv({ SESSION_SECRET: "" }))).toBe(false);
    expect(webSignInConfigured(adminEnv({ APPLE_SIGN_IN_CLIENT_ID: "" }))).toBe(false);
  });

  it("does not require ADMIN_EMAILS, because signing in is not administration", () => {
    expect(webSignInConfigured(adminEnv({ ADMIN_EMAILS: "" }))).toBe(true);
    // Nobody holds admin capabilities on that deployment, which is a valid
    // configuration: web sign-in works and /admin is unreachable for everyone.
    expect(adminAccessConfigured(adminEnv({ ADMIN_EMAILS: "" }))).toBe(false);
    expect(adminAccessConfigured(adminEnv())).toBe(true);
  });

  it("rejects short and placeholder session secrets", () => {
    expect(webSignInConfigured(adminEnv({ SESSION_SECRET: "too-short" }))).toBe(false);
    expect(webSignInConfigured(adminEnv({ SESSION_SECRET: "change-me" }))).toBe(false);
    expect(webSignInConfigured(adminEnv({ SESSION_SECRET: "a".repeat(64) }))).toBe(false);
  });
});

describe("ADMIN_EMAILS gating", () => {
  it("matches case-insensitively and trims", () => {
    const env = adminEnv();
    expect(isAdminEmail(env, "admin@example.com")).toBe(true);
    expect(isAdminEmail(env, "ADMIN@example.com")).toBe(true);
    expect(isAdminEmail(env, " other@example.com ")).toBe(true);
    expect(isAdminEmail(env, "stranger@example.com")).toBe(false);
  });
});

describe("session cookie", () => {
  it("round-trips a valid session", async () => {
    const env = adminEnv();
    const cookie = await makeSessionCookie(env, "admin@example.com");
    const setHeader = cookie.split(";")[0]; // "zw_session=...."
    const req = new Request("https://x/admin", {
      headers: { cookie: setHeader },
    });
    const session = await readSessionCookie(env, req);
    expect(session?.email).toBe("admin@example.com");
    expect(session?.csrf).toMatch(/^[A-Za-z0-9_-]+$/);
  });

  it("rejects a tampered signature", async () => {
    const env = adminEnv();
    const cookie = await makeSessionCookie(env, "admin@example.com");
    const value = cookie.split(";")[0].split("=")[1];
    const [payload, sig] = value.split(".");
    // Flip the last hex digit to something it definitely isn't. Overwriting it
    // with a fixed value instead left the signature untouched whenever it
    // already ended that way — a real 1-in-256 flake, since the payload carries
    // a random csrf token and the HMAC differs on every run.
    const tampered = `zw_session=${payload}.${sig.slice(0, -1)}${sig.endsWith("a") ? "b" : "a"}`;
    expect(tampered).not.toBe(`zw_session=${value}`);
    const req = new Request("https://x/admin", { headers: { cookie: tampered } });
    expect(await readSessionCookie(env, req)).toBeNull();
  });

  it("keeps the session but drops admin when the email leaves ADMIN_EMAILS", async () => {
    const env = adminEnv();
    const cookie = (await makeSessionCookie(env, "admin@example.com")).split(";")[0];
    const req = () => new Request("https://x/admin", { headers: { cookie } });

    expect((await readSessionCookie(env, req()))?.isAdmin).toBe(true);
    // Same secret, different ADMIN_EMAILS: the person is still signed in and
    // still owns their tenant. Only the capability is gone.
    const stricter = adminEnv({ ADMIN_EMAILS: "different@example.com" });
    const session = await readSessionCookie(stricter, req());
    expect(session?.email).toBe("admin@example.com");
    expect(session?.isAdmin).toBe(false);
  });

  it("rejects with no cookie header", async () => {
    const env = adminEnv();
    const req = new Request("https://x/admin");
    expect(await readSessionCookie(env, req)).toBeNull();
  });
});

describe("randomToken", () => {
  it("returns urlsafe base64 with sufficient entropy", () => {
    const a = randomToken();
    const b = randomToken();
    expect(a).not.toBe(b);
    expect(a).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(a.length).toBeGreaterThan(20);
  });
});

describe("admin routes (no Apple call required)", () => {
  it("/admin without session sends the visitor to sign in, and back afterwards", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(new Request("https://x/admin"), env, ctx);
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/login?next=%2Fadmin");
  });

  it("/admin shows config error when not configured", async () => {
    const env = makeEnv();
    const res = await (handler.fetch as any)(new Request("https://x/admin"), env, ctx);
    expect(res.status).toBe(500);
    const body = await res.text();
    expect(body).toContain("Admin not configured");
    // The page is unauthenticated: it must not enumerate which secrets are
    // unset, or it becomes a map of what to probe.
    expect(body).not.toContain("APPLE_SIGN_IN_CLIENT_ID");
    expect(body).not.toContain("APPLE_SIGN_IN_REDIRECT_URI");
    expect(body).not.toContain("ADMIN_EMAILS");
    expect(body).not.toContain("SESSION_SECRET");
    expect(body).not.toContain("API_KEYS");
    expect(body).not.toContain("ADMIN_API_TOKEN_LOGIN");
  });

  it("/login renders the login page with both methods when configured", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(
      new Request("https://x/login"),
      env,
      ctx,
    );
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain("Sign in with Apple");
    expect(body).toContain("/login/apple");
    expect(body).toContain("/login/api-token");
  });

  it("admin HTML responses include defense-in-depth security headers", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(
      new Request("https://x/login"),
      env,
      ctx,
    );

    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    // Not "no-referrer": that policy makes a browser send `Origin: null` on a
    // form POST and suppress Referer, so the CSRF origin check rejects every
    // form on the page. It shipped that way once and broke every admin
    // mutation in a browser while every test still passed, because `fetch()`
    // defaults to CORS mode and keeps its Origin. "same-origin" still strips
    // the referrer from cross-origin navigations.
    expect(res.headers.get("referrer-policy")).toBe("same-origin");
    const csp = res.headers.get("content-security-policy") ?? "";
    expect(csp).toContain("default-src 'none'");
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).toContain("form-action 'self'");
    expect(res.headers.get("cache-control")).toBe("no-store");
  });

  it("sensitive API responses and errors cannot be cached", async () => {
    const env = adminEnv();
    const unauthorized = await (handler.fetch as any)(
      new Request("https://x/v1/cards"),
      env,
      ctx,
    );
    const missing = await (handler.fetch as any)(
      new Request("https://x/v1/not-a-route"),
      env,
      ctx,
    );

    expect(unauthorized.headers.get("cache-control")).toBe("no-store");
    expect(missing.headers.get("cache-control")).toBe("no-store");
  });

  it("/login hides API-token form unless ADMIN_API_TOKEN_LOGIN=true", async () => {
    const env = adminEnv({ ADMIN_API_TOKEN_LOGIN: "" });
    const res = await (handler.fetch as any)(
      new Request("https://x/login"),
      env,
      ctx,
    );
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain("Sign in with Apple");
    expect(body).not.toContain("/login/api-token");
  });

  it("/login/apple redirects to appleid.apple.com", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(
      new Request("https://x/login/apple"),
      env,
      ctx,
    );
    expect(res.status).toBe(302);
    const loc = res.headers.get("location") ?? "";
    expect(loc.startsWith("https://appleid.apple.com/auth/authorize?")).toBe(true);
    expect(loc).toContain(`client_id=${encodeURIComponent("com.example.zerozerowidget.signin")}`);
    expect(loc).toContain("response_type=code+id_token");
    expect(loc).toContain("response_mode=form_post");
    const setCookies = res.headers.getSetCookie?.() ?? [res.headers.get("set-cookie") ?? ""];
    const joined = setCookies.join(";");
    expect(joined).toContain("zw_state=");
    expect(joined).toContain("zw_nonce=");
  });

  it("/login/api-token mints a session for a valid key", async () => {
    const env = adminEnv();
    const form = new URLSearchParams({ apiKey: TEST_ADMIN_TOKEN });
    const req = new Request("https://x/login/api-token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/admin");
    const setCookie = res.headers.get("set-cookie") ?? "";
    expect(setCookie).toContain("zw_session=");
  });

  it("/login/api-token rejects an invalid key", async () => {
    const env = adminEnv();
    const form = new URLSearchParams({ apiKey: "wrong" });
    const req = new Request("https://x/login/api-token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(401);
  });

  it("/login/api-token rejects oversized form bodies", async () => {
    const env = adminEnv();
    const req = new Request("https://x/login/api-token", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        "cf-connecting-ip": "203.0.113.11",
      },
      body: new URLSearchParams({ apiKey: "x".repeat(17 * 1024) }).toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(413);
    expect(await res.text()).toContain("form body is too large");
  });

  it("/auth/apple/callback rejects oversized form bodies", async () => {
    const env = adminEnv();
    const req = new Request("https://x/auth/apple/callback", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        "cf-connecting-ip": "203.0.113.13",
      },
      body: new URLSearchParams({ state: "x".repeat(17 * 1024) }).toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(413);
    expect(await res.text()).toContain("form body is too large");
  });

  it("/login/api-token refuses weak bootstrap configuration", async () => {
    const env = adminEnv({ API_KEYS: "dev-key-1" });
    const req = new Request("https://x/login/api-token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ apiKey: "dev-key-1" }).toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(500);
    const body = await res.text();
    expect(body).toContain("Admin not configured");
    expect(body).not.toContain("API_KEYS");
  });

  it("/login/api-token returns 403 when not explicitly enabled", async () => {
    const env = adminEnv({ ADMIN_API_TOKEN_LOGIN: "" });
    const form = new URLSearchParams({ apiKey: TEST_ADMIN_TOKEN });
    const req = new Request("https://x/login/api-token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(403);
  });

  it("/login/api-token rate-limits repeated attempts by client IP", async () => {
    const env = adminEnv();
    for (let i = 0; i < 10; i++) {
      const res = await (handler.fetch as any)(
        new Request("https://x/login/api-token", {
          method: "POST",
          headers: {
            "content-type": "application/x-www-form-urlencoded",
            "cf-connecting-ip": "203.0.113.10",
          },
          body: new URLSearchParams({ apiKey: "wrong" }).toString(),
        }),
        env,
        ctx,
      );
      expect(res.status).toBe(401);
    }

    const limited = await (handler.fetch as any)(
      new Request("https://x/login/api-token", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          "cf-connecting-ip": "203.0.113.10",
        },
        body: new URLSearchParams({ apiKey: TEST_ADMIN_TOKEN }).toString(),
      }),
      env,
      ctx,
    );
    expect(limited.status).toBe(429);
    expect(await limited.text()).toContain("Too many API-token login attempts");
  });

  it("/auth/apple/callback rate-limits repeated attempts by client IP", async () => {
    const env = adminEnv();
    for (let i = 0; i < 60; i++) {
      const res = await (handler.fetch as any)(
        new Request("https://x/auth/apple/callback", {
          method: "POST",
          headers: {
            "content-type": "application/x-www-form-urlencoded",
            "cf-connecting-ip": "203.0.113.12",
            cookie: "zw_state=expected; zw_nonce=nonce",
          },
          body: new URLSearchParams({ state: "wrong", id_token: "invalid" }).toString(),
        }),
        env,
        ctx,
      );
      expect(res.status).toBe(400);
    }

    const limited = await (handler.fetch as any)(
      new Request("https://x/auth/apple/callback", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          "cf-connecting-ip": "203.0.113.12",
          cookie: "zw_state=expected; zw_nonce=nonce",
        },
        body: new URLSearchParams({ state: "wrong", id_token: "invalid" }).toString(),
      }),
      env,
      ctx,
    );
    expect(limited.status).toBe(429);
    expect(await limited.text()).toContain("Too many Apple callback attempts");
  });

  it("api-token cookie is honored on /admin", async () => {
    const env = adminEnv();
    // Mint a cookie via the api-token login...
    const form = new URLSearchParams({ apiKey: TEST_ADMIN_TOKEN });
    const loginRes = await (handler.fetch as any)(
      new Request("https://x/login/api-token", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      }),
      env,
      ctx,
    );
    const setCookie = loginRes.headers.get("set-cookie") ?? "";
    const cookieValue = setCookie.split(";")[0];

    // ...then use it to access /admin.
    const dashRes = await (handler.fetch as any)(
      new Request("https://x/admin", { headers: { cookie: cookieValue } }),
      env,
      ctx,
    );
    expect(dashRes.status).toBe(200);
    const body = await dashRes.text();
    expect(body).toContain("Signed in");
    expect(body).toContain("via API token");
  });

  it("api-token cookie stops working after ADMIN_API_TOKEN_LOGIN is disabled", async () => {
    const enabled = adminEnv();
    const form = new URLSearchParams({ apiKey: TEST_ADMIN_TOKEN });
    const loginRes = await (handler.fetch as any)(
      new Request("https://x/login/api-token", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      }),
      enabled,
      ctx,
    );
    const cookieValue = (loginRes.headers.get("set-cookie") ?? "").split(";")[0];

    const disabled = adminEnv({ ADMIN_API_TOKEN_LOGIN: "" });
    const dashRes = await (handler.fetch as any)(
      new Request("https://x/admin", { headers: { cookie: cookieValue } }),
      disabled,
      ctx,
    );
    expect(dashRes.status).toBe(302);
    expect(dashRes.headers.get("location")).toBe("/login?next=%2Fadmin");
  });

  it("api-token cookie stops working after API_KEYS rotation removes its bootstrap token", async () => {
    const env = adminEnv({ API_KEYS: `${TEST_ADMIN_TOKEN},${OTHER_ADMIN_TOKEN}` });
    const form = new URLSearchParams({ apiKey: TEST_ADMIN_TOKEN });
    const loginRes = await (handler.fetch as any)(
      new Request("https://x/login/api-token", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      }),
      env,
      ctx,
    );
    const cookieValue = (loginRes.headers.get("set-cookie") ?? "").split(";")[0];

    const rotated = adminEnv({ API_KEYS: OTHER_ADMIN_TOKEN });
    const dashRes = await (handler.fetch as any)(
      new Request("https://x/admin", { headers: { cookie: cookieValue } }),
      rotated,
      ctx,
    );
    expect(dashRes.status).toBe(302);
    expect(dashRes.headers.get("location")).toBe("/login?next=%2Fadmin");
  });

  it("api-token cookie remains valid when API_KEYS rotation keeps its bootstrap token", async () => {
    const env = adminEnv({ API_KEYS: `${OTHER_ADMIN_TOKEN},${TEST_ADMIN_TOKEN}` });
    const form = new URLSearchParams({ apiKey: TEST_ADMIN_TOKEN });
    const loginRes = await (handler.fetch as any)(
      new Request("https://x/login/api-token", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      }),
      env,
      ctx,
    );
    const cookieValue = (loginRes.headers.get("set-cookie") ?? "").split(";")[0];

    const rotated = adminEnv({ API_KEYS: `${NEW_ADMIN_TOKEN},${TEST_ADMIN_TOKEN}` });
    const dashRes = await (handler.fetch as any)(
      new Request("https://x/admin", { headers: { cookie: cookieValue } }),
      rotated,
      ctx,
    );
    expect(dashRes.status).toBe(200);
    expect(await dashRes.text()).toContain("via API token");
  });

  it("/admin/api-keys creates a tenant token and returns the raw token once", async () => {
    const env = adminEnv();
    const { cookie, csrf } = await adminCookie(env);
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          "x-csrf-token": csrf,
          cookie,
        },
        body: JSON.stringify({
          ownerEmail: "customer-a@example.com",
          label: "Webhook manager",
          scopePreset: "webhook-manager",
        }),
      }),
      env,
      ctx,
    );

    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      token: string;
      tenant: { id: string; ownerEmail: string };
      apiKey: { id: string; tokenHash: string; label: string; scopes: string[] };
    };
    expect(body.token).toMatch(/^zw_/);
    expect(body.tenant.ownerEmail).toBe("customer-a@example.com");
    expect(body.apiKey.label).toBe("Webhook manager");
    expect(body.apiKey.scopes).toEqual(["tenant:read", "webhook:manage"]);
    expect(body.apiKey.tokenHash).not.toBe(body.token);

    const dash = await (handler.fetch as any)(
      new Request("https://x/admin", { headers: { cookie } }),
      env,
      ctx,
    );
    const html = await dash.text();
    expect(html).toContain("customer-a@example.com");
    expect(html).not.toContain(body.token);
    expect(html).toContain("Select a tenant to view cards");
    expect(html).not.toContain("Cards <span");
  });

  it("/admin mutation rejects missing CSRF tokens", async () => {
    const env = adminEnv();
    const { cookie } = await adminCookie(env);
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          cookie,
          origin: "https://x",
        },
        body: JSON.stringify({ ownerEmail: "customer-csrf@example.com", label: "iPhone" }),
      }),
      env,
      ctx,
    );
    expect(res.status).toBe(403);
    expect(await res.text()).toContain("Invalid CSRF token");
  });

  it("/admin mutation rejects a request carrying neither Origin nor Referer", async () => {
    const env = adminEnv();
    const { cookie, csrf } = await adminCookie(env);
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", cookie },
        body: new URLSearchParams({ csrf, ownerEmail: "no-origin@example.com" }).toString(),
      }),
      env,
      ctx,
    );
    expect(res.status).toBe(403);
    expect(await res.text()).toContain("Invalid request origin");
  });

  it("/admin mutation accepts a header-borne CSRF token without Origin", async () => {
    const env = adminEnv();
    const { cookie, csrf } = await adminCookie(env);
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          cookie,
          "x-csrf-token": csrf,
        },
        body: JSON.stringify({ ownerEmail: "header-csrf@example.com", label: "script" }),
      }),
      env,
      ctx,
    );
    expect(res.status).toBe(201);
  });

  it("/admin mutation rejects cross-origin requests even with a valid CSRF token", async () => {
    const env = adminEnv();
    const { cookie, csrf } = await adminCookie(env);
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          cookie,
          origin: "https://evil.example",
        },
        body: new URLSearchParams({
          csrf,
          ownerEmail: "customer-origin@example.com",
          label: "default",
        }).toString(),
      }),
      env,
      ctx,
    );
    expect(res.status).toBe(403);
    expect(await res.text()).toContain("Invalid request origin");
  });

  it("/admin/api-keys form creates tenants from the global dashboard and tokens from selected tenants", async () => {
    const env = adminEnv();
    const { cookie, csrf } = await adminCookie(env);
    const createTenantRes = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          cookie,
          origin: "https://x",
        },
        body: new URLSearchParams({
          csrf,
          ownerEmail: "customer-form@example.com",
          label: "default",
        }).toString(),
      }),
      env,
      ctx,
    );
    expect(createTenantRes.status).toBe(201);
    const createTenantHtml = await createTenantRes.text();
    expect(createTenantHtml).toContain("Copy this token now");
    expect(createTenantHtml).toContain("back to tenant");

    const match = /tenant=([^"]+)/.exec(createTenantHtml);
    expect(match?.[1]).toBeTruthy();
    const tenantId = decodeURIComponent(match![1]);

    const selected = await (handler.fetch as any)(
      new Request(`https://x/admin?tenant=${encodeURIComponent(tenantId)}`, {
        headers: { cookie },
      }),
      env,
      ctx,
    );
    const selectedHtml = await selected.text();
    expect(selectedHtml).toContain("Create API token");
    expect(selectedHtml).toContain(`name="tenantId" value="${tenantId}"`);
    expect(selectedHtml).toContain(`name="csrf" value="${csrf}"`);
    expect(selectedHtml).toContain("customer-form@example.com");
  });

  it("/admin/api-keys form rejects token creation without selecting a tenant", async () => {
    const env = adminEnv();
    const { cookie, csrf } = await adminCookie(env);
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          cookie,
          origin: "https://x",
        },
        body: new URLSearchParams({ csrf, label: "missing tenant" }).toString(),
      }),
      env,
      ctx,
    );
    expect(res.status).toBe(400);
    expect(await res.text()).toContain("Select a tenant before creating an API token");
  });

  it("/admin scopes operational rows to the selected tenant", async () => {
    const env = adminEnv();
    await seedApiKey(env, "tenant-a-key", "tenant-a");
    await seedApiKey(env, "tenant-b-key", "tenant-b");

    await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/cards/upsert",
        {
          method: "POST",
          body: JSON.stringify({
            id: "tenant-a-card",
            template: "summary",
            title: "Tenant A card",
            status: "good",
          }),
        },
        "tenant-a-key",
      ),
      env,
      ctx,
    );
    await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/cards/upsert",
        {
          method: "POST",
          body: JSON.stringify({
            id: "tenant-b-card",
            template: "summary",
            title: "Tenant B card",
            status: "warning",
          }),
        },
        "tenant-b-key",
      ),
      env,
      ctx,
    );

    const { cookie } = await adminCookie(env);
    const unselected = await (handler.fetch as any)(
      new Request("https://x/admin", { headers: { cookie } }),
      env,
      ctx,
    );
    const unselectedHtml = await unselected.text();
    expect(unselectedHtml).toContain("tenant-a@example.com");
    expect(unselectedHtml).toContain("tenant-b@example.com");
    expect(unselectedHtml).not.toContain("Tenant A card");
    expect(unselectedHtml).not.toContain("Tenant B card");

    const selected = await (handler.fetch as any)(
      new Request("https://x/admin?tenant=tenant-a", { headers: { cookie } }),
      env,
      ctx,
    );
    const selectedHtml = await selected.text();
    expect(selectedHtml).toContain("Tenant A card");
    expect(selectedHtml).toContain("Rate limits");
    expect(selectedHtml).toContain("Card upserts");
    expect(selectedHtml).toContain("All writes");
    expect(selectedHtml).not.toContain("Tenant B card");
  });

  it("/admin selected tenant can delete cards, widget tokens, and live activity state", async () => {
    const env = adminEnv();
    await seedApiKey(env, "tenant-a-key", "tenant-a");
    await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/cards/upsert",
        {
          method: "POST",
          body: JSON.stringify({
            id: "tenant-a-card",
            template: "summary",
            title: "Tenant A card",
            status: "good",
          }),
        },
        "tenant-a-key",
      ),
      env,
      ctx,
    );
    await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/widgets/register-push-token",
        {
          method: "POST",
          body: JSON.stringify({
            deviceId: "device-a",
            widgetKind: "ZeroZeroWidgetCardWidget",
            widgetPushToken: "deadbeefcafe0a",
          }),
        },
        "tenant-a-key",
      ),
      env,
      ctx,
    );
    await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/live-activities/start",
        {
          method: "POST",
          body: JSON.stringify({
            externalActivityId: "pending-a",
            kind: "job",
            title: "Pending A",
            state: "queued",
          }),
        },
        "tenant-a-key",
      ),
      env,
      ctx,
    );
    await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/live-activities/register",
        {
          method: "POST",
          body: JSON.stringify({
            deviceId: "device-a",
            localActivityId: "local-a",
            externalActivityId: "activity-a",
            kind: "job",
            pushToken: "deadbeefcafe1a",
          }),
        },
        "tenant-a-key",
      ),
      env,
      ctx,
    );
    await (handler.fetch as any)(
      authedRequest(
        "https://x/v1/live-activities/register-start-token",
        {
          method: "POST",
          body: JSON.stringify({
            deviceId: "device-a",
            attributesType: "ZeroZeroWidgetActivityAttributes",
            pushToken: "deadbeefcafe2a",
          }),
        },
        "tenant-a-key",
      ),
      env,
      ctx,
    );

    const { cookie, csrf } = await adminCookie(env);
    const before = await (handler.fetch as any)(
      new Request("https://x/admin?tenant=tenant-a", { headers: { cookie } }),
      env,
      ctx,
    );
    const beforeHtml = await before.text();
    expect(beforeHtml).toContain("Tenant A card");
    expect(beforeHtml).toContain("device-a");
    expect(beforeHtml).toContain("activity-a");
    expect(beforeHtml).toContain("pending-a");
    expect(beforeHtml).toContain("ZeroZeroWidgetActivityAttributes");

    const deletePaths = [
      "/admin/tenants/tenant-a/cards/tenant-a-card/delete",
      "/admin/tenants/tenant-a/widget-tokens/device-a/ZeroZeroWidgetCardWidget/delete",
      "/admin/tenants/tenant-a/live-activities/activity-a/delete",
      "/admin/tenants/tenant-a/pending-live-activities/pending-a/delete",
      "/admin/tenants/tenant-a/start-tokens/device-a/ZeroZeroWidgetActivityAttributes/delete",
    ];
    for (const path of deletePaths) {
      const res = await (handler.fetch as any)(
        new Request(`https://x${path}`, {
          method: "POST",
          headers: {
            cookie,
            "content-type": "application/x-www-form-urlencoded",
            origin: "https://x",
          },
          body: new URLSearchParams({ csrf }).toString(),
        }),
        env,
        ctx,
      );
      expect(res.status).toBe(302);
      expect(res.headers.get("location")).toBe("/admin?tenant=tenant-a");
    }

    const after = await (handler.fetch as any)(
      new Request("https://x/admin?tenant=tenant-a", { headers: { cookie } }),
      env,
      ctx,
    );
    const afterHtml = await after.text();
    expect(afterHtml).not.toContain("Tenant A card");
    expect(afterHtml).not.toContain("activity-a");
    expect(afterHtml).not.toContain("pending-a");
    expect(afterHtml).not.toContain("ZeroZeroWidgetActivityAttributes");
  });

  it("/admin/api-keys/:id/revoke revokes a generated token", async () => {
    const env = adminEnv();
    const { cookie, csrf } = await adminCookie(env);
    const createRes = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          "x-csrf-token": csrf,
          cookie,
        },
        body: JSON.stringify({ ownerEmail: "customer-b@example.com", label: "test" }),
      }),
      env,
      ctx,
    );
    const created = (await createRes.json()) as { token: string; apiKey: { id: string } };

    expect(
      (await (handler.fetch as any)(
        new Request("https://x/v1/cards", {
          headers: { authorization: `Bearer ${created.token}` },
        }),
        env,
        ctx,
      )).status,
    ).toBe(200);

    const revokeRes = await (handler.fetch as any)(
      new Request(`https://x/admin/api-keys/${created.apiKey.id}/revoke`, {
        method: "POST",
        headers: {
          accept: "application/json",
          "x-csrf-token": csrf,
          cookie,
        },
      }),
      env,
      ctx,
    );
    expect(revokeRes.status).toBe(200);

    expect(
      (await (handler.fetch as any)(
        new Request("https://x/v1/cards", {
          headers: { authorization: `Bearer ${created.token}` },
        }),
        env,
        ctx,
      )).status,
    ).toBe(401);
  });

  it("/logout clears the session and redirects to login", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(
      new Request("https://x/logout"),
      env,
      ctx,
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/login");
    expect((res.headers.get("set-cookie") ?? "")).toContain("Max-Age=0");
  });

  it("/auth/apple/callback rejects state mismatch", async () => {
    const env = adminEnv();
    const form = new URLSearchParams({ state: "wrong", id_token: "x.y.z" });
    const req = new Request("https://x/auth/apple/callback", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        cookie: "zw_state=actual; zw_nonce=actual",
      },
      body: form.toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(400);
    expect(await res.text()).toContain("state mismatch");
  });

  it("/auth/apple/callback rejects an unverified Apple email", async () => {
    const env = adminEnv();
    const nonce = "expected-nonce";
    const { token, jwk } = await makeAppleIdToken({
      aud: env.APPLE_SIGN_IN_CLIENT_ID!,
      email: "admin@example.com",
      emailVerified: false,
      nonce,
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ keys: [jwk] }), { status: 200 })),
    );

    const req = new Request("https://x/auth/apple/callback", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        "cf-connecting-ip": "203.0.113.14",
        cookie: `zw_state=expected; zw_nonce=${nonce}`,
      },
      body: new URLSearchParams({ state: "expected", id_token: token }).toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(403);
    expect(await res.text()).toContain("Apple email is not verified");
    expect(res.headers.get("set-cookie")).toBeNull();
  });
});



