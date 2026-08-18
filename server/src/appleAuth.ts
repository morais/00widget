import type { Env } from "./types";

// Apple identity: building the authorize URL and validating the id_token that
// comes back. What a validated identity is then *allowed* to do lives in
// webSession.ts; the browser flow that ties the two together lives in
// webLogin.ts.




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

  // Verify the signature before reading a single claim. Claim values end up in
  // error strings and logs, and until the signature checks out they are
  // attacker-supplied text rather than anything Apple asserted.
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

  return claims;
}






// Random URL-safe state/nonce. Used in OAuth flow.
export function randomToken(byteLen = 24): string {
  const bytes = new Uint8Array(byteLen);
  crypto.getRandomValues(bytes);
  return b64urlBytes(bytes);
}

// ---------- Encoding helpers ----------

export function b64url(input: string): string {
  return b64urlBytes(new TextEncoder().encode(input));
}

function b64urlBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export function b64urlDecodeToText(s: string): string {
  return new TextDecoder().decode(b64urlDecodeToBytes(s));
}

function b64urlDecodeToBytes(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

export async function hmacSha256Hex(secret: string, data: string): Promise<string> {
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

export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
