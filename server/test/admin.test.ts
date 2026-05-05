import { describe, it, expect } from "vitest";
import handler from "../src/index";
import {
  isAdminEmail,
  makeSessionCookie,
  readSessionCookie,
  randomToken,
  appleSignInConfigured,
} from "../src/appleAuth";
import { authedRequest, makeEnv, seedApiKey } from "./helpers";

const ctx = {} as ExecutionContext;

function adminEnv(overrides = {}) {
  return makeEnv({
    APPLE_SIGN_IN_CLIENT_ID: "com.example.zerozerowidget.signin",
    APPLE_SIGN_IN_REDIRECT_URI: "https://example.com/admin/auth/apple/callback",
    ADMIN_EMAILS: "admin@example.com,Other@Example.com",
    SESSION_SECRET: "test-session-secret-123456",
    ...overrides,
  });
}

describe("appleSignInConfigured", () => {
  it("is false when any required env is missing", () => {
    expect(appleSignInConfigured(makeEnv())).toBe(false);
    expect(appleSignInConfigured(adminEnv({ ADMIN_EMAILS: "" }))).toBe(false);
    expect(appleSignInConfigured(adminEnv({ SESSION_SECRET: "" }))).toBe(false);
  });
  it("is true when all four are set", () => {
    expect(appleSignInConfigured(adminEnv())).toBe(true);
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
    const setHeader = cookie.split(";")[0]; // "zw_admin=...."
    const req = new Request("https://x/admin", {
      headers: { cookie: setHeader },
    });
    const session = await readSessionCookie(env, req);
    expect(session?.email).toBe("admin@example.com");
  });

  it("rejects a tampered signature", async () => {
    const env = adminEnv();
    const cookie = await makeSessionCookie(env, "admin@example.com");
    const value = cookie.split(";")[0].split("=")[1];
    const [payload, sig] = value.split(".");
    const tampered = `zw_admin=${payload}.${sig.slice(0, -2)}aa`;
    const req = new Request("https://x/admin", { headers: { cookie: tampered } });
    expect(await readSessionCookie(env, req)).toBeNull();
  });

  it("rejects when email is no longer in ADMIN_EMAILS", async () => {
    const env = adminEnv();
    const cookie = await makeSessionCookie(env, "admin@example.com");
    const setHeader = cookie.split(";")[0];

    const stricter = adminEnv({ ADMIN_EMAILS: "different@example.com" });
    const req = new Request("https://x/admin", { headers: { cookie: setHeader } });
    // Different env (different ADMIN_EMAILS) but SAME secret to isolate the email check.
    expect(await readSessionCookie(stricter, req)).toBeNull();
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
  it("/admin without session redirects to /admin/login when configured", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(new Request("https://x/admin"), env, ctx);
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/admin/login");
  });

  it("/admin shows config error when not configured", async () => {
    const env = makeEnv();
    const res = await (handler.fetch as any)(new Request("https://x/admin"), env, ctx);
    expect(res.status).toBe(500);
    const body = await res.text();
    expect(body).toContain("Admin not configured");
    expect(body).toContain("APPLE_SIGN_IN_CLIENT_ID");
  });

  it("/admin/login renders the login page with both methods when configured", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/login"),
      env,
      ctx,
    );
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain("Sign in with Apple");
    expect(body).toContain("/admin/login/apple");
    expect(body).toContain("/admin/login/api-token");
  });

  it("/admin/login hides API-token form when ADMIN_API_TOKEN_LOGIN=false", async () => {
    const env = adminEnv({ ADMIN_API_TOKEN_LOGIN: "false" });
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/login"),
      env,
      ctx,
    );
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain("Sign in with Apple");
    expect(body).not.toContain("/admin/login/api-token");
  });

  it("/admin/login/apple redirects to appleid.apple.com", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/login/apple"),
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
    expect(joined).toContain("zw_admin_state=");
    expect(joined).toContain("zw_admin_nonce=");
  });

  it("/admin/login/api-token mints a session for a valid key", async () => {
    const env = adminEnv();
    const form = new URLSearchParams({ apiKey: "test-key" });
    const req = new Request("https://x/admin/login/api-token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/admin");
    const setCookie = res.headers.get("set-cookie") ?? "";
    expect(setCookie).toContain("zw_admin=");
  });

  it("/admin/login/api-token rejects an invalid key", async () => {
    const env = adminEnv();
    const form = new URLSearchParams({ apiKey: "wrong" });
    const req = new Request("https://x/admin/login/api-token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(401);
  });

  it("/admin/login/api-token returns 403 when disabled", async () => {
    const env = adminEnv({ ADMIN_API_TOKEN_LOGIN: "false" });
    const form = new URLSearchParams({ apiKey: "test-key" });
    const req = new Request("https://x/admin/login/api-token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(403);
  });

  it("api-token cookie is honored on /admin", async () => {
    const env = adminEnv();
    // Mint a cookie via the api-token login...
    const form = new URLSearchParams({ apiKey: "test-key" });
    const loginRes = await (handler.fetch as any)(
      new Request("https://x/admin/login/api-token", {
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
    const form = new URLSearchParams({ apiKey: "test-key" });
    const loginRes = await (handler.fetch as any)(
      new Request("https://x/admin/login/api-token", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      }),
      enabled,
      ctx,
    );
    const cookieValue = (loginRes.headers.get("set-cookie") ?? "").split(";")[0];

    const disabled = adminEnv({ ADMIN_API_TOKEN_LOGIN: "false" });
    const dashRes = await (handler.fetch as any)(
      new Request("https://x/admin", { headers: { cookie: cookieValue } }),
      disabled,
      ctx,
    );
    expect(dashRes.status).toBe(302);
    expect(dashRes.headers.get("location")).toBe("/admin/login");
  });

  it("/admin/api-keys creates a tenant token and returns the raw token once", async () => {
    const env = adminEnv();
    const cookie = (await makeSessionCookie(env, "admin@example.com")).split(";")[0];
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          cookie,
        },
        body: JSON.stringify({ ownerEmail: "customer-a@example.com", label: "iPhone" }),
      }),
      env,
      ctx,
    );

    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      token: string;
      tenant: { id: string; ownerEmail: string };
      apiKey: { id: string; tokenHash: string; label: string };
    };
    expect(body.token).toMatch(/^zw_/);
    expect(body.tenant.ownerEmail).toBe("customer-a@example.com");
    expect(body.apiKey.label).toBe("iPhone");
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

  it("/admin/api-keys form creates tenants from the global dashboard and tokens from selected tenants", async () => {
    const env = adminEnv();
    const cookie = (await makeSessionCookie(env, "admin@example.com")).split(";")[0];
    const createTenantRes = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          cookie,
        },
        body: new URLSearchParams({
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
    expect(selectedHtml).toContain("customer-form@example.com");
  });

  it("/admin/api-keys form rejects token creation without selecting a tenant", async () => {
    const env = adminEnv();
    const cookie = (await makeSessionCookie(env, "admin@example.com")).split(";")[0];
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          cookie,
        },
        body: new URLSearchParams({ label: "missing tenant" }).toString(),
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

    const cookie = (await makeSessionCookie(env, "admin@example.com")).split(";")[0];
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
            widgetPushToken: "widget-token-a",
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
            pushToken: "activity-token-a",
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
            pushToken: "start-token-a",
          }),
        },
        "tenant-a-key",
      ),
      env,
      ctx,
    );

    const cookie = (await makeSessionCookie(env, "admin@example.com")).split(";")[0];
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
        new Request(`https://x${path}`, { method: "POST", headers: { cookie } }),
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
    const cookie = (await makeSessionCookie(env, "admin@example.com")).split(";")[0];
    const createRes = await (handler.fetch as any)(
      new Request("https://x/admin/api-keys", {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
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

  it("/admin/logout clears the session and redirects to login", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/logout"),
      env,
      ctx,
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("/admin/login");
    expect((res.headers.get("set-cookie") ?? "")).toContain("Max-Age=0");
  });

  it("/admin/auth/apple/callback rejects state mismatch", async () => {
    const env = adminEnv();
    const form = new URLSearchParams({ state: "wrong", id_token: "x.y.z" });
    const req = new Request("https://x/admin/auth/apple/callback", {
      method: "POST",
      headers: {
        "content-type": "application/x-www-form-urlencoded",
        cookie: "zw_admin_state=actual; zw_admin_nonce=actual",
      },
      body: form.toString(),
    });
    const res = await (handler.fetch as any)(req, env, ctx);
    expect(res.status).toBe(400);
    expect(await res.text()).toContain("state mismatch");
  });
});
