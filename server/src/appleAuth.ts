import type { Env } from "./types";
import {
  adminApiTokensAreSecure,
  configuredAdminApiTokens,
  isSecureAdminSecret,
} from "./adminSecurity";

// Sign in with Apple — web flow.
//
// References:
//   https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_js/configuring_your_webpage_for_sign_in_with_apple
//   https://developer.apple.com/documentation/signinwithapplerestapi
//
// Flow:
// 1. /admin/login → redirect the browser to https://appleid.apple.com/auth/authorize
//    with our Services ID as client_id, our callback as redirect_uri,
//    response_type=code id_token, response_mode=form_post.
// 2. Apple POSTs the result to /admin/auth/apple/callback as form data.
// 3. We validate the id_token JWT (RS256, signed by Apple, against the JWKS
//    at https://appleid.apple.com/auth/keys) and check that the email claim
//    matches one in ADMIN_EMAILS.
// 4. We mint an HMAC-signed session cookie and redirect to /admin.

export type AdminAuthMethod = "apple" | "api-token";

export interface AdminSession {
  // For "apple": Apple's email claim. For "api-token": a label like "api-token".
  email: string;
  method: AdminAuthMethod;
  iat: number;
  exp: number;
  csrf: string;
  // API-token sessions are bound to the bootstrap token that minted them.
  // If API_KEYS rotates, this hash stops matching and the session is rejected.
  apiTokenHash?: string;
}

export function apiTokenLoginEnabled(env: Env): boolean {
  return env.ADMIN_API_TOKEN_LOGIN === "true";
}

export function apiTokenLoginConfigured(env: Env): boolean {
  return apiTokenLoginEnabled(env) &&
    isSecureAdminSecret(env.SESSION_SECRET) &&
    adminApiTokensAreSecure(env);
}

const COOKIE_NAME = "zw_admin";
const SESSION_TTL_SECONDS = 24 * 60 * 60;
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
const APPLE_AUTH_URL = "https://appleid.apple.com/auth/authorize";

interface AppleIdTokenClaims {
  iss: string;
  aud: string;
  exp: number;
  iat: number;
  sub: string;
  nonce?: string;
  email?: string;
  email_verified?: boolean | string;
}

export function appleSignInConfigured(env: Env): boolean {
  return Boolean(
    env.APPLE_SIGN_IN_CLIENT_ID &&
      env.APPLE_SIGN_IN_REDIRECT_URI &&
      env.ADMIN_EMAILS &&
      isSecureAdminSecret(env.SESSION_SECRET),
  );
}

export function appAppleLoginConfigured(env: Env): boolean {
  return env.APPLE_APP_LOGIN_ENABLED === "true" && Boolean(env.APPLE_APP_SIGN_IN_CLIENT_ID);
}

export function buildAuthorizeURL(env: Env, state: string, nonce: string): string {
  const params = new URLSearchParams({
    client_id: env.APPLE_SIGN_IN_CLIENT_ID!,
    redirect_uri: env.APPLE_SIGN_IN_REDIRECT_URI!,
    response_type: "code id_token",
    response_mode: "form_post",
    scope: "name email",
    state,
    nonce,
  });
  return `${APPLE_AUTH_URL}?${params.toString()}`;
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

export function isAppleEmailVerified(value: boolean | string | undefined): boolean {
  return value === true || value === "true";
}

// ---------- ID token validation ----------

interface AppleJwk {
  kty: string;
  kid: string;
  use: string;
  alg: string;
  n: string;
  e: string;
}

interface JwksCache {
  fetchedAt: number;
  keys: AppleJwk[];
}

let jwksCache: JwksCache | null = null;
const JWKS_TTL_SECONDS = 60 * 60;

async function fetchAppleJwks(): Promise<AppleJwk[]> {
  const now = Math.floor(Date.now() / 1000);
  if (jwksCache && now - jwksCache.fetchedAt < JWKS_TTL_SECONDS) return jwksCache.keys;
  const res = await fetch(APPLE_JWKS_URL);
  if (!res.ok) throw new Error(`Apple JWKS fetch failed: ${res.status}`);
  const body = (await res.json()) as { keys: AppleJwk[] };
  jwksCache = { fetchedAt: now, keys: body.keys };
  return body.keys;
}

export function __resetAppleJwksCache(): void {
  jwksCache = null;
}

export async function validateAppleIdToken(
  env: Env,
  idToken: string,
  expectedNonce: string,
): Promise<AppleIdTokenClaims> {
  return validateAppleIdTokenForAudience(env, idToken, env.APPLE_SIGN_IN_CLIENT_ID, expectedNonce);
}

export async function validateAppleIdTokenForAudience(
  _env: Env,
  idToken: string,
  audience: string | undefined,
  expectedNonce?: string,
): Promise<AppleIdTokenClaims> {
  if (!audience) throw new Error("missing Apple client id");
  const [headerB64, payloadB64, signatureB64] = idToken.split(".");
  if (!headerB64 || !payloadB64 || !signatureB64) {
    throw new Error("malformed id_token");
  }

  const header = JSON.parse(b64urlDecodeToText(headerB64)) as { kid: string; alg: string };
  if (header.alg !== "RS256") throw new Error(`unsupported alg ${header.alg}`);

  const claims = JSON.parse(b64urlDecodeToText(payloadB64)) as AppleIdTokenClaims;
  const now = Math.floor(Date.now() / 1000);

  if (claims.iss !== "https://appleid.apple.com") throw new Error(`bad iss ${claims.iss}`);
  if (claims.aud !== audience) throw new Error(`bad aud ${claims.aud}`);
  if (claims.exp < now) throw new Error("id_token expired");
  if (expectedNonce) {
    if (!claims.nonce || !constantTimeEqual(claims.nonce, expectedNonce)) {
      throw new Error("nonce mismatch");
    }
  }

  const jwks = await fetchAppleJwks();
  const jwk = jwks.find((k) => k.kid === header.kid);
  if (!jwk) throw new Error(`unknown kid ${header.kid}`);

  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: jwk.alg, ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );

  const signature = b64urlDecodeToBytes(signatureB64);
  const data = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, data);
  if (!ok) throw new Error("id_token signature invalid");

  return claims;
}

// ---------- Session cookie (HMAC-signed) ----------

export async function makeSessionCookie(
  env: Env,
  email: string,
  method: AdminAuthMethod = "apple",
  options: { apiTokenHash?: string } = {},
): Promise<string> {
  if (!isSecureAdminSecret(env.SESSION_SECRET)) {
    throw new Error("SESSION_SECRET must be a strong random value of at least 32 bytes");
  }
  if (method === "api-token" && !options.apiTokenHash) {
    throw new Error("api-token sessions require apiTokenHash");
  }
  const now = Math.floor(Date.now() / 1000);
  const session: AdminSession = {
    email: email.toLowerCase(),
    method,
    iat: now,
    exp: now + SESSION_TTL_SECONDS,
    csrf: randomToken(18),
    ...(method === "api-token" ? { apiTokenHash: options.apiTokenHash } : {}),
  };
  const payload = b64url(JSON.stringify(session));
  const sig = await hmacSha256Hex(env.SESSION_SECRET!, payload);
  const value = `${payload}.${sig}`;
  return `${COOKIE_NAME}=${value}; Path=/admin; Max-Age=${SESSION_TTL_SECONDS}; HttpOnly; Secure; SameSite=Lax`;
}

export function clearSessionCookie(): string {
  return `${COOKIE_NAME}=; Path=/admin; Max-Age=0; HttpOnly; Secure; SameSite=Lax`;
}

export async function readSessionCookie(env: Env, req: Request): Promise<AdminSession | null> {
  if (!isSecureAdminSecret(env.SESSION_SECRET)) return null;
  const cookieHeader = req.headers.get("cookie");
  if (!cookieHeader) return null;
  const cookies = Object.fromEntries(
    cookieHeader.split(";").map((s) => {
      const [k, ...v] = s.trim().split("=");
      return [k, v.join("=")];
    }),
  );
  const raw = cookies[COOKIE_NAME];
  if (!raw) return null;
  const [payload, sig] = raw.split(".");
  if (!payload || !sig) return null;

  const expected = await hmacSha256Hex(env.SESSION_SECRET!, payload);
  if (!constantTimeEqual(sig, expected)) return null;

  let session: AdminSession;
  try {
    session = JSON.parse(b64urlDecodeToText(payload)) as AdminSession;
  } catch {
    return null;
  }
  const now = Math.floor(Date.now() / 1000);
  if (session.exp < now) return null;
  if (!session.csrf) return null;
  // Validation depends on how the user signed in:
  //   apple    → the email must still be in ADMIN_EMAILS (the operator may
  //              have rotated the list since the cookie was minted)
  //   api-token → the cookie must still be bound to one of the currently
  //              configured API_KEYS. If the operator rotates API_KEYS or
  //              disables api-token login, existing sessions stop working.
  const method = session.method;
  if (method === "apple") {
    if (!isAdminEmail(env, session.email)) return null;
  } else if (method === "api-token") {
    if (!apiTokenLoginEnabled(env)) return null;
    if (!session.apiTokenHash) return null;
    if (!(await isCurrentAdminApiTokenHash(env, session.apiTokenHash))) return null;
  } else {
    return null;
  }
  return session;
}

export async function hashAdminApiToken(token: string): Promise<string> {
  const data = new TextEncoder().encode(token.trim());
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function isCurrentAdminApiTokenHash(env: Env, tokenHash: string): Promise<boolean> {
  if (!adminApiTokensAreSecure(env)) return false;
  const allowed = configuredAdminApiTokens(env);
  let valid = false;
  for (const token of allowed) {
    const currentHash = await hashAdminApiToken(token);
    valid = constantTimeEqual(currentHash, tokenHash) || valid;
  }
  return valid;
}

// Random URL-safe state/nonce. Used in OAuth flow.
export function randomToken(byteLen = 24): string {
  const bytes = new Uint8Array(byteLen);
  crypto.getRandomValues(bytes);
  return b64urlBytes(bytes);
}

// ---------- Encoding helpers ----------

function b64url(input: string): string {
  return b64urlBytes(new TextEncoder().encode(input));
}

function b64urlBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function b64urlDecodeToText(s: string): string {
  return new TextDecoder().decode(b64urlDecodeToBytes(s));
}

function b64urlDecodeToBytes(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

async function hmacSha256Hex(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
