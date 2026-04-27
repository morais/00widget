import { describe, it, expect } from "vitest";
import handler from "../src/index";
import {
  isAdminEmail,
  makeSessionCookie,
  readSessionCookie,
  randomToken,
  appleSignInConfigured,
} from "../src/appleAuth";
import { makeEnv } from "./helpers";

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

  it("/admin/login redirects to appleid.apple.com when configured", async () => {
    const env = adminEnv();
    const res = await (handler.fetch as any)(
      new Request("https://x/admin/login"),
      env,
      ctx,
    );
    expect(res.status).toBe(302);
    const loc = res.headers.get("location") ?? "";
    expect(loc.startsWith("https://appleid.apple.com/auth/authorize?")).toBe(true);
    expect(loc).toContain(`client_id=${encodeURIComponent("com.example.zerozerowidget.signin")}`);
    expect(loc).toContain("response_type=code+id_token");
    expect(loc).toContain("response_mode=form_post");
    // State + nonce cookies set
    const setCookies = res.headers.getSetCookie?.() ?? [res.headers.get("set-cookie") ?? ""];
    const joined = setCookies.join(";");
    expect(joined).toContain("zw_admin_state=");
    expect(joined).toContain("zw_admin_nonce=");
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
