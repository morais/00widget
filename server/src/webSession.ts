import {
  b64url,
  b64urlDecodeToText,
  constantTimeEqual,
  hmacSha256Hex,
  randomToken,
} from "./appleAuth";
import {
  adminApiTokensAreSecure,
  configuredAdminApiTokens,
  isSecureAdminSecret,
} from "./adminSecurity";
import { htmlResponse, renderError } from "./html";
import type { Env } from "./types";

// The browser session, and the capability that sits on top of it.
//
// These are two different things and used to be one. Signing in on the web
// meant *being an administrator*: `ADMIN_EMAILS` gated the login itself, so a
// normal person who had signed up in the iOS app could not authenticate at all,
// and every web surface was therefore an admin surface by construction.
//
// Now signing in establishes identity — who you are, and which tenant is yours.
// Administration is a separate check (`session.isAdmin`) that a handful of
// handlers make on top of it. Ordinary users get a session and can approve an
// MCP connector for their own tenant; nothing else about `/admin` loosens,
// because every route under it asserts the capability rather than assuming it.
//
// The session never carries authority of its own: it names an identity, and the
// handler re-resolves what that identity may touch. See `identity.ts`.

export type WebAuthMethod = "apple" | "api-token";

export interface WebSession {
  /// For "apple": Apple's email claim. For "api-token": a label like "api-token".
  email: string;
  method: WebAuthMethod;
  iat: number;
  exp: number;
  csrf: string;
  /// Apple's stable subject id, the same value the iOS app signs in with. It is
  /// how a web session is matched back to the account created in the app —
  /// more reliable than the email, which Apple may relay or the user may change.
  appleSub?: string;
  /// API-token sessions are bound to the bootstrap token that minted them.
  /// If API_KEYS rotates, this hash stops matching and the session is rejected.
  apiTokenHash?: string;
}

/// A session plus the capability decision made at read time, so rotating
/// ADMIN_EMAILS takes effect on the next request rather than on the next login.
export interface WebPrincipal extends WebSession {
  isAdmin: boolean;
}

const COOKIE_NAME = "zw_session";
const SESSION_TTL_SECONDS = 24 * 60 * 60;

// Path=/ because the web surface is no longer one directory. A session has to
// reach /connect/* and /admin/* alike; SameSite=Lax keeps it off cross-site
// requests, and it is HttpOnly, so widening the path does not widen who can
// read it.
const COOKIE_PATH = "/";

// ---------- Configuration ----------

export function webSignInConfigured(env: Env): boolean {
  return Boolean(
    env.APPLE_SIGN_IN_CLIENT_ID
      && env.APPLE_SIGN_IN_REDIRECT_URI
      && isSecureAdminSecret(env.SESSION_SECRET),
  );
}

/// Deliberately does not require ADMIN_EMAILS: a deployment may have web
/// sign-in with no administrators at all, which simply leaves /admin
/// unreachable for everyone.
export function adminAccessConfigured(env: Env): boolean {
  return adminEmails(env).length > 0 && (webSignInConfigured(env) || apiTokenLoginConfigured(env));
}

export function apiTokenLoginEnabled(env: Env): boolean {
  return env.ADMIN_API_TOKEN_LOGIN === "true";
}

export function apiTokenLoginConfigured(env: Env): boolean {
  return apiTokenLoginEnabled(env)
    && isSecureAdminSecret(env.SESSION_SECRET)
    && adminApiTokensAreSecure(env);
}

export function adminEmails(env: Env): string[] {
  return (env.ADMIN_EMAILS ?? "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

export function isAdminEmail(env: Env, email: string): boolean {
  return adminEmails(env).includes(email.trim().toLowerCase());
}

// ---------- Cookie ----------

export async function makeSessionCookie(
  env: Env,
  email: string,
  method: WebAuthMethod = "apple",
  options: { apiTokenHash?: string; appleSub?: string } = {},
): Promise<string> {
  if (!isSecureAdminSecret(env.SESSION_SECRET)) {
    throw new Error("SESSION_SECRET must be a strong random value of at least 32 bytes");
  }
  if (method === "api-token" && !options.apiTokenHash) {
    throw new Error("api-token sessions require apiTokenHash");
  }
  const now = Math.floor(Date.now() / 1000);
  const session: WebSession = {
    email: email.toLowerCase(),
    method,
    iat: now,
    exp: now + SESSION_TTL_SECONDS,
    csrf: randomToken(18),
    ...(options.appleSub ? { appleSub: options.appleSub } : {}),
    ...(method === "api-token" ? { apiTokenHash: options.apiTokenHash } : {}),
  };
  const payload = b64url(JSON.stringify(session));
  const sig = await hmacSha256Hex(env.SESSION_SECRET!, payload);
  return `${COOKIE_NAME}=${payload}.${sig}; Path=${COOKIE_PATH}; Max-Age=${SESSION_TTL_SECONDS}; HttpOnly; Secure; SameSite=Lax`;
}

export function clearSessionCookie(): string {
  return `${COOKIE_NAME}=; Path=${COOKIE_PATH}; Max-Age=0; HttpOnly; Secure; SameSite=Lax`;
}

export async function readSessionCookie(env: Env, req: Request): Promise<WebPrincipal | null> {
  if (!isSecureAdminSecret(env.SESSION_SECRET)) return null;
  const raw = parseCookies(req.headers.get("cookie"))[COOKIE_NAME];
  if (!raw) return null;
  const [payload, sig] = raw.split(".");
  if (!payload || !sig) return null;

  const expected = await hmacSha256Hex(env.SESSION_SECRET!, payload);
  if (!constantTimeEqual(sig, expected)) return null;

  let session: WebSession;
  try {
    session = JSON.parse(b64urlDecodeToText(payload)) as WebSession;
  } catch {
    return null;
  }
  const now = Math.floor(Date.now() / 1000);
  if (session.exp < now) return null;
  if (!session.csrf || !session.email) return null;

  // What still has to hold depends on how the person signed in:
  //   apple     → nothing beyond the signature. Any verified Apple identity may
  //               hold a session; whether it can *do* anything is decided by the
  //               tenant it resolves to and by `isAdmin`.
  //   api-token → the cookie must still be bound to one of the currently
  //               configured API_KEYS, so rotating them ends those sessions.
  if (session.method === "api-token") {
    if (!apiTokenLoginEnabled(env)) return null;
    if (!session.apiTokenHash) return null;
    if (!(await isCurrentAdminApiTokenHash(env, session.apiTokenHash))) return null;
    // The bootstrap credential exists to administer a deployment before anyone
    // has signed in with Apple, so it is admin by definition and owns no tenant.
    return { ...session, isAdmin: true };
  }
  if (session.method !== "apple") return null;
  return { ...session, isAdmin: isAdminEmail(env, session.email) };
}

export async function hashAdminApiToken(token: string): Promise<string> {
  const data = new TextEncoder().encode(token.trim());
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function isCurrentAdminApiTokenHash(env: Env, tokenHash: string): Promise<boolean> {
  if (!adminApiTokensAreSecure(env)) return false;
  let valid = false;
  for (const token of configuredAdminApiTokens(env)) {
    const currentHash = await hashAdminApiToken(token);
    valid = constantTimeEqual(currentHash, tokenHash) || valid;
  }
  return valid;
}

// ---------- Request guards ----------

export async function requireWebSession(req: Request, env: Env): Promise<WebPrincipal | null> {
  return readSessionCookie(env, req);
}

/// A state-changing request from a signed-in person: same-origin, with the
/// session's CSRF token. Returns a Response to send when either fails.
export async function requireWebMutationSession(
  req: Request,
  env: Env,
): Promise<WebPrincipal | Response> {
  const session = await requireWebSession(req, env);
  if (!session) return redirectToSignIn(req);
  if (!sameOriginRequest(req)) {
    return htmlResponse(renderError("Invalid request origin."), 403);
  }
  const token = await csrfTokenFromRequest(req);
  if (!token || !constantTimeEqual(token, session.csrf)) {
    return htmlResponse(renderError("Invalid CSRF token."), 403);
  }
  return session;
}

/// As above, and the principal must hold admin capabilities. Every `/admin`
/// route goes through one of these two, so being signed in is never on its own
/// enough to reach one.
export async function requireAdminMutationSession(
  req: Request,
  env: Env,
): Promise<WebPrincipal | Response> {
  const session = await requireWebMutationSession(req, env);
  if (session instanceof Response) return session;
  if (!session.isAdmin) return notAnAdminResponse(session);
  return session;
}

export function notAnAdminResponse(session: WebSession): Response {
  return htmlResponse(
    renderError(
      `Signed in as ${session.email}, which is not an administrator of this deployment.`,
    ),
    403,
  );
}

export function redirectToSignIn(req: Request): Response {
  const url = new URL(req.url);
  const next = safeNextPath(`${url.pathname}${url.search}`);
  return new Response(null, {
    status: 302,
    headers: { Location: next ? `/login?next=${encodeURIComponent(next)}` : "/login" },
  });
}

export function sameOriginRequest(req: Request): boolean {
  const expected = new URL(req.url).origin;
  const origin = req.headers.get("origin");
  if (origin) return origin === expected;
  const referer = req.headers.get("referer");
  if (referer) {
    try {
      return new URL(referer).origin === expected;
    } catch {
      return false;
    }
  }
  // Neither header present. Browsers always send Origin on a form POST, so
  // this is a non-browser client — accept it only when the CSRF token arrived
  // in a custom header, which a cross-origin page cannot set without a CORS
  // preflight this Worker never answers. Falling through to "allow" would let
  // a header-stripping intermediary bypass the origin check entirely.
  return req.headers.get("x-csrf-token") !== null;
}

export async function csrfTokenFromRequest(req: Request): Promise<string | null> {
  const header = req.headers.get("x-csrf-token")?.trim();
  if (header) return header;
  const contentType = req.headers.get("content-type") ?? "";
  try {
    if (contentType.includes("application/json")) {
      const data = (await req.clone().json()) as Record<string, unknown>;
      return typeof data.csrf === "string" ? data.csrf.trim() || null : null;
    }
    const form = await req.clone().formData();
    const value = form.get("csrf");
    return typeof value === "string" ? value.trim() || null : null;
  } catch {
    return null;
  }
}

// ---------- Post-sign-in destination ----------

// Carried through Apple's cross-site form_post round trip in a cookie, so a
// person who lands on the consent screen unauthenticated returns to it after
// signing in. Only same-origin absolute paths under a known web prefix are
// honoured, which is what keeps `?next=` from becoming an open redirect: no
// scheme, no host, and no protocol-relative "//evil" form survives.
const NEXT_PREFIXES = ["/admin", "/connect/"];

export function safeNextPath(value: string | null | undefined): string | undefined {
  const next = value?.trim();
  if (!next) return undefined;
  if (!/^\/[A-Za-z0-9._~\-/]*(?:\?[^#\s]*)?$/.test(next)) return undefined;
  if (next.startsWith("//")) return undefined;
  const path = next.split("?")[0];
  if (!NEXT_PREFIXES.some((prefix) => path === prefix || path.startsWith(prefix))) return undefined;
  return next;
}

export function parseCookies(header: string | null): Record<string, string> {
  if (!header) return {};
  return Object.fromEntries(
    header.split(";").map((part) => {
      const [key, ...rest] = part.trim().split("=");
      return [key, rest.join("=")];
    }),
  );
}
