import { isValidEmail, type Env } from "./types";
import {
  buildAuthorizeURL,
  isAppleEmailVerified,
  randomToken,
  validateAppleIdToken,
} from "./appleAuth";
import { adminApiTokensAreSecure, isSecureAdminSecret } from "./adminSecurity";
import { createTenantForOwner, isValidApiKey } from "./auth";
import { baseHTML, esc, enc, htmlResponse, renderError } from "./html";
import { putAppleAccount, resolveIdentity } from "./identity";
import { incrementRateLimitBuckets, rateLimitResponse } from "./rateLimit";
import {
  adminEmails,
  apiTokenLoginConfigured,
  apiTokenLoginEnabled,
  clearSessionCookie,
  hashAdminApiToken,
  isAdminEmail,
  makeSessionCookie,
  parseCookies,
  safeNextPath,
  webSignInConfigured,
} from "./webSession";

// Sign in with Apple — web flow.
//
// References:
//   https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_js/configuring_your_webpage_for_sign_in_with_apple
//   https://developer.apple.com/documentation/signinwithapplerestapi
//
// Flow:
// 1. /login/apple → redirect the browser to https://appleid.apple.com/auth/authorize
//    with our Services ID as client_id, our callback as redirect_uri,
//    response_type=code id_token, response_mode=form_post.
// 2. Apple POSTs the result to /auth/apple/callback as form data.
// 3. We validate the id_token JWT (RS256, signed by Apple, against the JWKS
//    at https://appleid.apple.com/auth/keys).
// 4. We resolve which tenant this person already owns and mint an HMAC-signed
//    session cookie.
//
// Step 4 is where signing in stops short of signing up. A verified Apple
// identity with no tenant behind it is turned away unless WEB_SIGNUP_ENABLED
// says otherwise, because accounts are meant to be created in the iOS app:
// someone who finds this endpoint and has never used the app should not become
// a tenant by visiting a URL. `resolveIdentity` never creates anything, and the
// one call below that can is explicit and gated.

const STATE_COOKIE = "zw_state";
const NONCE_COOKIE = "zw_nonce";
const NEXT_COOKIE = "zw_next";
const API_TOKEN_LABEL = "api-token";
const AUTH_FORM_MAX_BYTES = 16 * 1024;

export function webSignupEnabled(env: Env): boolean {
  return env.WEB_SIGNUP_ENABLED === "true";
}

// ---------- Routes ----------

export async function handleLogin(req: Request, env: Env): Promise<Response> {
  const apple = webSignInConfigured(env);
  const apiToken = apiTokenLoginConfigured(env);
  if (!apple && !apiToken) return htmlResponse(renderConfigError(env), 500);
  const next = safeNextPath(new URL(req.url).searchParams.get("next"));
  return htmlResponse(renderLoginPage({ apple, apiToken, next }));
}

export async function handleLoginApple(req: Request, env: Env): Promise<Response> {
  if (!webSignInConfigured(env)) return htmlResponse(renderConfigError(env), 500);
  const state = randomToken();
  const nonce = randomToken();
  const headers = new Headers({ Location: buildAuthorizeURL(env, state, nonce) });
  headers.append("Set-Cookie", roundTripCookie(STATE_COOKIE, state));
  headers.append("Set-Cookie", roundTripCookie(NONCE_COOKIE, nonce));
  const next = safeNextPath(new URL(req.url).searchParams.get("next"));
  if (next) headers.append("Set-Cookie", roundTripCookie(NEXT_COOKIE, encodeURIComponent(next)));
  return new Response(null, { status: 302, headers });
}

/// Bootstrap sign-in for an operator holding a value from API_KEYS. It grants
/// administration without an identity, which is the whole point — it exists for
/// the deployment that has no signed-up accounts yet — so it is opt-in and
/// never resolves or creates a tenant.
export async function handleLoginApiToken(req: Request, env: Env): Promise<Response> {
  if (!apiTokenLoginEnabled(env)) {
    return htmlResponse(
      renderError("API-token login is disabled (set ADMIN_API_TOKEN_LOGIN=true to enable)."),
      403,
    );
  }
  if (!isSecureAdminSecret(env.SESSION_SECRET) || !adminApiTokensAreSecure(env)) {
    return htmlResponse(renderConfigError(env), 500);
  }
  const limited = await enforceApiTokenLoginRateLimit(req, env);
  if (limited) return limited;
  let form: FormData;
  try {
    form = await parseAuthForm(req);
  } catch (error) {
    return formErrorResponse(error);
  }
  const apiKey = String(form.get("apiKey") ?? "");
  if (!apiKey) return htmlResponse(renderError("API token is required"), 400);
  if (!isValidApiKey(env, apiKey)) return htmlResponse(renderError("Invalid API token."), 401);

  const cookie = await makeSessionCookie(env, API_TOKEN_LABEL, "api-token", {
    apiTokenHash: await hashAdminApiToken(apiKey),
  });
  const next = typeof form.get("next") === "string" ? String(form.get("next")) : undefined;
  const headers = new Headers({ Location: safeNextPath(next) ?? "/admin" });
  headers.append("Set-Cookie", cookie);
  return new Response(null, { status: 302, headers });
}

export async function handleAppleCallback(req: Request, env: Env): Promise<Response> {
  if (!webSignInConfigured(env)) return htmlResponse(renderConfigError(env), 500);
  const limited = await enforceAppleCallbackRateLimit(req, env);
  if (limited) return limited;

  const cookies = parseCookies(req.headers.get("cookie"));
  const expectedState = cookies[STATE_COOKIE];
  const expectedNonce = cookies[NONCE_COOKIE];

  let form: FormData;
  try {
    form = await parseAuthForm(req);
  } catch (error) {
    return formErrorResponse(error);
  }

  const state = String(form.get("state") ?? "");
  const idToken = String(form.get("id_token") ?? "");
  const error = form.get("error");
  if (error) return htmlResponse(renderError(`Apple returned error: ${error}`), 400);
  if (!state || state !== expectedState) {
    return htmlResponse(renderError("state mismatch — try again"), 400);
  }
  if (!idToken) return htmlResponse(renderError("no id_token in callback"), 400);
  if (!expectedNonce) return htmlResponse(renderError("nonce cookie missing"), 400);

  let claims;
  try {
    claims = await validateAppleIdToken(env, idToken, expectedNonce);
  } catch (err) {
    return htmlResponse(renderError(`token validation failed: ${(err as Error).message}`), 401);
  }

  if (!claims.email) {
    return htmlResponse(
      renderError(
        "Apple didn't return an email. Re-link your account on Apple ID → 'Sign in with Apple' and try again.",
      ),
      403,
    );
  }
  if (!isAppleEmailVerified(claims.email_verified)) {
    return htmlResponse(renderError("Apple email is not verified."), 403);
  }
  // Same check the app login makes, for the same reason: this becomes a
  // tenant's owner_email, which joins later sign-ins and reaches the signup
  // alert's mail headers.
  if (!isValidEmail(claims.email)) {
    return htmlResponse(renderError("Apple returned an email this server cannot accept."), 403);
  }

  const email = claims.email.trim().toLowerCase();
  const admin = isAdminEmail(env, email);
  const identity = await resolveIdentity(env, { appleSub: claims.sub, email });

  if (identity) {
    // Bind the Apple subject to the tenant we found by email, so the next
    // sign-in — here or in the app — resolves without depending on the address.
    await putAppleAccount(env, {
      appleSub: claims.sub,
      tenantId: identity.tenantId,
      email: identity.ownerEmail || email,
    });
  } else if (webSignupEnabled(env)) {
    const tenant = await createTenantForOwner(env, email);
    await putAppleAccount(env, { appleSub: claims.sub, tenantId: tenant.id, email });
  } else if (!admin) {
    // Not an account, not an administrator, and this deployment does not sign
    // people up on the web. Nothing was created reaching this point.
    return htmlResponse(renderNoAccountPage(email), 403);
  }

  const cookie = await makeSessionCookie(env, email, "apple", { appleSub: claims.sub });
  const headers = new Headers({
    Location: safeNextPath(decodeCookieValue(cookies[NEXT_COOKIE])) ?? (admin ? "/admin" : "/"),
  });
  headers.append("Set-Cookie", cookie);
  for (const name of [STATE_COOKIE, NONCE_COOKIE, NEXT_COOKIE]) {
    headers.append("Set-Cookie", expireRoundTripCookie(name));
  }
  return new Response(null, { status: 302, headers });
}

export async function handleLogout(_req: Request, _env: Env): Promise<Response> {
  const headers = new Headers({ Location: "/login" });
  headers.append("Set-Cookie", clearSessionCookie());
  return new Response(null, { status: 302, headers });
}

// ---------- Rendering ----------

function renderLoginPage(opts: { apple: boolean; apiToken: boolean; next?: string }): string {
  const appleHref = opts.next ? `/login/apple?next=${enc(opts.next)}` : "/login/apple";
  const appleBlock = opts.apple
    ? `<a class="button button-apple" href="${esc(appleHref)}">Sign in with Apple</a>`
    : `<p class="muted">Sign in with Apple is not configured.</p>`;

  const nextField = opts.next
    ? `<input type="hidden" name="next" value="${esc(opts.next)}">`
    : "";
  const apiTokenBlock = opts.apiToken
    ? `<form method="post" action="/login/api-token" class="api-token-form">
         ${nextField}
         <label for="apiKey">API token</label>
         <input id="apiKey" type="password" name="apiKey" autocomplete="off" autofocus required>
         <button type="submit" class="button">Sign in with API token</button>
         <p class="muted">Operator bootstrap. Opt in by setting <code>ADMIN_API_TOKEN_LOGIN=true</code>.</p>
       </form>`
    : "";

  const separator = opts.apple && opts.apiToken ? `<div class="divider"><span>or</span></div>` : "";

  return baseHTML(
    "00Widget · Sign in",
    `<header><h1>00Widget</h1></header>
     <section class="login">
       <h2>Sign in</h2>
       <p class="muted">Use the same Apple ID you signed in with on the 00Widget app.</p>
       ${appleBlock}
       ${separator}
       ${apiTokenBlock}
     </section>`,
  );
}

function renderNoAccountPage(email: string): string {
  return baseHTML(
    "00Widget · No account",
    `<header><h1>00Widget</h1></header>
     <section>
       <h2>No 00Widget account for ${esc(email)}</h2>
       <p>Accounts are created in the iOS app. Install 00Widget, sign in with the same
       Apple ID, and come back — this page will recognise you.</p>
       <p class="muted">Signing in here never creates an account on its own.</p>
     </section>`,
  );
}

function renderConfigError(env: Env): string {
  const apple: string[] = [];
  if (!env.APPLE_SIGN_IN_CLIENT_ID) apple.push("APPLE_SIGN_IN_CLIENT_ID");
  if (!env.APPLE_SIGN_IN_REDIRECT_URI) apple.push("APPLE_SIGN_IN_REDIRECT_URI");
  if (!isSecureAdminSecret(env.SESSION_SECRET)) {
    apple.push("SESSION_SECRET (strong random value, 32+ bytes)");
  }

  const apiToken: string[] = [];
  if (!adminApiTokensAreSecure(env)) {
    apiToken.push("API_KEYS (every token must be a strong random value of 32+ bytes)");
  }
  if (!isSecureAdminSecret(env.SESSION_SECRET)) {
    apiToken.push("SESSION_SECRET (strong random value, 32+ bytes)");
  }

  console.warn("web_sign_in.not_configured", {
    appleMissing: apple,
    adminEmailsConfigured: adminEmails(env).length > 0,
    apiTokenLoginEnabled: apiTokenLoginEnabled(env),
    apiTokenMissing: apiTokenLoginEnabled(env) ? apiToken : undefined,
  });

  return baseHTML(
    "00Widget · Sign-in not configured",
    `<header><h1>00Widget</h1></header>
     <section><h2>Admin not configured</h2>
     <p>No sign-in method is available.</p>
     <p class="muted">If you are the operator, the missing configuration is
     named in this Worker's logs. Setup walkthrough:
     <code>server/README.md</code> → "Web sign-in".</p></section>`,
  );
}

// ---------- Helpers ----------

async function enforceApiTokenLoginRateLimit(req: Request, env: Env): Promise<Response | null> {
  const exceeded = await incrementRateLimitBuckets(env, [
    { policy: "adminApiTokenLoginIpHour", key: loginIpKey(req) },
  ]);
  if (!exceeded) return null;
  if (wantsJson(req)) return rateLimitResponse(exceeded);
  return htmlResponse(
    renderError(`Too many API-token login attempts. Try again after ${formatWindow(exceeded.retryAfter)}.`),
    429,
  );
}

async function enforceAppleCallbackRateLimit(req: Request, env: Env): Promise<Response | null> {
  const exceeded = await incrementRateLimitBuckets(env, [
    { policy: "adminAppleCallbackIpHour", key: loginIpKey(req) },
  ]);
  if (!exceeded) return null;
  return htmlResponse(
    renderError(`Too many Apple callback attempts. Try again after ${formatWindow(exceeded.retryAfter)}.`),
    429,
  );
}

function loginIpKey(req: Request): string {
  const cfIp = req.headers.get("cf-connecting-ip")?.trim();
  const forwardedIp = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return `web-login:${cfIp || forwardedIp || "unknown"}`;
}

class AuthFormError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "AuthFormError";
  }
}

async function parseAuthForm(req: Request): Promise<FormData> {
  const contentLength = req.headers.get("content-length")?.trim();
  if (contentLength && /^\d+$/.test(contentLength) && Number(contentLength) > AUTH_FORM_MAX_BYTES) {
    throw new AuthFormError("form body is too large", 413);
  }

  const chunks: Uint8Array[] = [];
  let total = 0;
  const reader = req.body?.getReader();
  if (reader) {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > AUTH_FORM_MAX_BYTES) {
        await reader.cancel();
        throw new AuthFormError("form body is too large", 413);
      }
      chunks.push(value);
    }
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const contentType = req.headers.get("content-type");
  if (!contentType) throw new AuthFormError("missing form body", 400);
  try {
    return await new Response(bytes, { headers: { "content-type": contentType } }).formData();
  } catch {
    throw new AuthFormError("missing or malformed form body", 400);
  }
}

function formErrorResponse(error: unknown): Response {
  if (error instanceof AuthFormError) {
    return htmlResponse(renderError(error.message), error.status);
  }
  return htmlResponse(renderError("missing or malformed form body"), 400);
}

function wantsJson(req: Request): boolean {
  const accept = req.headers.get("accept") ?? "";
  const contentType = req.headers.get("content-type") ?? "";
  return accept.includes("application/json") || contentType.includes("application/json");
}

function formatWindow(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.ceil(seconds / 60)}m`;
  return `${Math.ceil(seconds / 3600)}h`;
}

// SameSite=None because Apple POSTs the callback from appleid.apple.com; the
// browser must still send these. Path=/ so the callback, which no longer lives
// under /admin, receives them.
function roundTripCookie(name: string, value: string): string {
  return `${name}=${value}; Path=/; Max-Age=600; HttpOnly; Secure; SameSite=None`;
}

function expireRoundTripCookie(name: string): string {
  return `${name}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=None`;
}

function decodeCookieValue(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    return decodeURIComponent(value);
  } catch {
    return undefined;
  }
}
