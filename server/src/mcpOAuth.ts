import { b64url, b64urlDecodeToText, constantTimeEqual, hmacSha256Hex, randomToken } from "./appleAuth";
import { isSecureAdminSecret } from "./adminSecurity";
import { ApiScopePresets, canonicalScope, createApiKey, type ApiScope } from "./auth";
import { baseHTML, esc, htmlResponse } from "./html";
import {
  redirectToSignIn,
  requireWebMutationSession,
  requireWebSession,
  resolveWebTenantIdentity,
  type WebPrincipal,
} from "./webSession";
import { json } from "./http";
import { enforceRateLimits } from "./rateLimit";
import { MCP_PATH } from "./mcp";
import { FieldLimits, type Env } from "./types";

// OAuth 2.1 authorization server for the MCP endpoint.
//
// It exists because of one constraint we do not control: ChatGPT connectors can
// present an OAuth access token or nothing at all — never a custom API key or a
// custom header. Every other client of this Worker sends `Authorization: Bearer
// zw_…` directly, so this module is a bridge, not a second auth system. What it
// hands back at the end of the dance *is* an ordinary `api_keys` row with the
// producer scope preset, which means `requireAuth` needs no MCP special case
// and the admin dashboard lists and revokes these credentials for free.
//
// Registered clients and authorization codes are self-contained values signed
// with SESSION_SECRET rather than rows:
//
//   client_id  zwc_<b64url(JSON)>.<hmac>   redirect URIs + display name
//   code       <b64url(JSON)>.<hmac>       jti, client, tenant, redirect, PKCE
//
// D1 bills index maintenance as rows written at 1000x the cost of rows read
// (see AGENTS.md), and *issuing* is pure write traffic: a code is minted on
// every authorize, and nothing needs to remember one that is never redeemed.
// Signing sidesteps a table, a migration and a sweep for all of that.
//
// Redeeming is the exception, and `mcp_authorization_codes` is the one thing
// here that is stored. A signed value cannot be marked used, so single-use once
// rested on the 60-second lifetime plus PKCE — which makes a code inert to
// anyone without the verifier, and does nothing about the client that holds it.
// Every redemption calls `createApiKey`, so a retrying client silently
// accumulated 90-day publisher credentials on the operator's account. One row
// per successful exchange buys the property the signature cannot; the volume is
// already capped by `mcpTokenIpHour`.

const AUTHORIZE_PATH = "/connect/mcp/authorize";
const TOKEN_PATH = "/oauth/token";
const REGISTER_PATH = "/oauth/register";

const CLIENT_ID_PREFIX = "zwc_";
const CODE_TTL_SECONDS = 60;
const CLIENT_NAME_MAX_LENGTH = 120;
const REDIRECT_URI_MAX_LENGTH = 512;
const MAX_REDIRECT_URIS = 5;
const OAUTH_BODY_MAX_BYTES = 8 * 1024;

// Domain separation. A client_id blob and an authorization code are both
// "<payload>.<hmac of payload>" under the same key; without a purpose tag, one
// could be presented where the other is expected.
const CLIENT_SIGNING_PURPOSE = "mcp-client-v1";
const CODE_SIGNING_PURPOSE = "mcp-code-v1";

const GRANTABLE_SCOPES: readonly ApiScope[] = ApiScopePresets.mcp;

interface RegisteredClient {
  /// Display name, shown on the consent screen.
  n: string;
  /// Redirect URIs, exactly as registered.
  r: string[];
  /// Issued-at, seconds.
  ia: number;
}

interface AuthorizationCode {
  /// Unique id for this code, recorded on redemption so it cannot be redeemed
  /// twice. The one property a signed, storage-free value cannot carry.
  jti: string;
  /// Client id the code was issued to.
  cid: string;
  /// Tenant the operator picked on the consent screen.
  tid: string;
  /// Redirect URI used at the authorize step; the token request must match.
  ru: string;
  /// PKCE S256 challenge.
  cc: string;
  /// Granted scopes.
  sc: ApiScope[];
  /// Expiry, seconds.
  exp: number;
  /// Admin identity that approved, for the credential label.
  sub: string;
}

function mcpEnabled(env: Env): boolean {
  return env.MCP_ENABLED === "true";
}

/// The MCP endpoint can only be *reached* if it can also be authorized, and
/// authorizing means signing values and identifying an operator through the
/// admin session. Reporting that as configuration rather than letting the
/// authorize step fail halfway through the browser flow.
export function mcpConfigured(env: Env): boolean {
  return mcpEnabled(env) && isSecureAdminSecret(env.SESSION_SECRET);
}

function protectedResourceMetadataPath(): string {
  return "/.well-known/oauth-protected-resource";
}

// ---------- Discovery ----------

export async function handleProtectedResourceMetadata(req: Request, env: Env): Promise<Response> {
  if (!mcpConfigured(env)) return json({ error: "not found" }, 404);
  const origin = new URL(req.url).origin;
  return metadataResponse({
    resource: `${origin}${MCP_PATH}`,
    authorization_servers: [origin],
    scopes_supported: GRANTABLE_SCOPES,
    bearer_methods_supported: ["header"],
    resource_name: "00Widget",
    resource_documentation: `${origin}/llms.md`,
  });
}

export async function handleAuthorizationServerMetadata(req: Request, env: Env): Promise<Response> {
  if (!mcpConfigured(env)) return json({ error: "not found" }, 404);
  const origin = new URL(req.url).origin;
  return metadataResponse({
    issuer: origin,
    authorization_endpoint: `${origin}${AUTHORIZE_PATH}`,
    token_endpoint: `${origin}${TOKEN_PATH}`,
    registration_endpoint: `${origin}${REGISTER_PATH}`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code"],
    // PKCE is mandatory and S256 only: OAuth 2.1 drops "plain", and a
    // stateless code leans on the verifier for its single-use property.
    code_challenge_methods_supported: ["S256"],
    // Clients are public. There is no client secret to present, by design —
    // one would have to be stored, and storage is what this module avoids.
    token_endpoint_auth_methods_supported: ["none"],
    scopes_supported: GRANTABLE_SCOPES,
    service_documentation: `${origin}/llms.md`,
  });
}

function metadataResponse(body: unknown): Response {
  return json(body, 200, {
    // Public, non-secret, and fetched by every client before it can do
    // anything. Cached for the same five minutes as the landing page.
    "cache-control": "public, max-age=300",
  });
}

/// The 401 that starts the OAuth dance. Clients discover where to authorize
/// from `resource_metadata`; without this header ChatGPT reports the connector
/// as unreachable rather than prompting to sign in.
export function mcpUnauthorized(req: Request, message: string): Response {
  const origin = new URL(req.url).origin;
  const params = [
    `error="invalid_token"`,
    `error_description="${message.replace(/["\\]/g, "")}"`,
    `resource_metadata="${origin}${protectedResourceMetadataPath()}"`,
  ].join(", ");
  return json({ error: message }, 401, { "www-authenticate": `Bearer ${params}` });
}

// ---------- Dynamic client registration (RFC 7591) ----------

export async function handleRegister(req: Request, env: Env): Promise<Response> {
  if (!mcpConfigured(env)) return json({ error: "not found" }, 404);
  const limited = await enforceRateLimits(env, [
    { policy: "mcpClientRegisterIpDay", key: clientIpKey(req) },
  ]);
  if (limited) return limited;

  let body: Record<string, unknown>;
  try {
    body = (await readJsonBody(req)) as Record<string, unknown>;
  } catch {
    return oauthError("invalid_client_metadata", "malformed JSON body");
  }
  if (!body || typeof body !== "object") {
    return oauthError("invalid_client_metadata", "malformed JSON body");
  }

  const rawUris = body.redirect_uris;
  if (!Array.isArray(rawUris) || rawUris.length === 0 || rawUris.length > MAX_REDIRECT_URIS) {
    return oauthError("invalid_redirect_uri", `redirect_uris must hold 1-${MAX_REDIRECT_URIS} entries`);
  }
  const redirectUris: string[] = [];
  for (const uri of rawUris) {
    if (typeof uri !== "string" || uri.length > REDIRECT_URI_MAX_LENGTH || !isAllowedRedirectUri(uri)) {
      return oauthError(
        "invalid_redirect_uri",
        "redirect_uris must be https URLs without a fragment (http is accepted only for localhost)",
      );
    }
    redirectUris.push(uri);
  }

  const name = typeof body.client_name === "string" && body.client_name.trim()
    ? body.client_name.trim().slice(0, CLIENT_NAME_MAX_LENGTH)
    : "MCP client";

  const issuedAt = Math.floor(Date.now() / 1000);
  const clientId = await signClient(env, { n: name, r: redirectUris, ia: issuedAt });
  return json(
    {
      client_id: clientId,
      client_id_issued_at: issuedAt,
      client_name: name,
      redirect_uris: redirectUris,
      grant_types: ["authorization_code"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
      scope: GRANTABLE_SCOPES.join(" "),
    },
    201,
    { "cache-control": "no-store" },
  );
}

// ---------- Authorization ----------

export async function handleAuthorize(req: Request, env: Env): Promise<Response> {
  if (!mcpConfigured(env)) return json({ error: "not found" }, 404);
  const url = new URL(req.url);
  const request = await parseAuthorizeParams(env, url.searchParams);
  if ("error" in request) {
    // Nothing has been validated far enough to redirect safely, so the error
    // is rendered rather than bounced back to a possibly-forged redirect_uri.
    return htmlResponse(renderAuthorizeError(request.error), 400);
  }

  const session = await requireWebSession(req, env);
  if (!session) return redirectToSignIn(req);

  const identity = await resolveWebTenantIdentity(env, session);
  if (!identity) return htmlResponse(renderNoTenantError(session), 409);

  return consentResponse(renderConsentPage(request, session), request.redirectUri);
}

export async function handleAuthorizeDecision(req: Request, env: Env): Promise<Response> {
  if (!mcpConfigured(env)) return json({ error: "not found" }, 404);
  const session = await requireWebMutationSession(req, env);
  if (session instanceof Response) return session;

  let form: FormData;
  try {
    form = await readFormBody(req);
  } catch {
    return htmlResponse(renderAuthorizeError("malformed form body"), 400);
  }

  const request = await parseAuthorizeParams(env, new URLSearchParams(formEntries(form)));
  if ("error" in request) return htmlResponse(renderAuthorizeError(request.error), 400);

  // The tenant is never taken from the form. It is re-resolved from the signed
  // -in identity on the way through, so a connector can only ever be pointed at
  // the approver's own account — including for an administrator, who has other
  // ways to issue a credential on someone else's behalf and should have to use
  // one deliberately.
  const identity = await resolveWebTenantIdentity(env, session);
  if (!identity) return htmlResponse(renderNoTenantError(session), 409);

  if (String(form.get("decision") ?? "") !== "approve") {
    return redirectToClient(request.redirectUri, {
      error: "access_denied",
      error_description: "the operator declined",
      state: request.state,
    });
  }

  const code = await signCode(env, {
    jti: randomToken(18),
    cid: request.clientId,
    tid: identity.tenantId,
    ru: request.redirectUri,
    cc: request.codeChallenge,
    sc: request.scopes,
    exp: Math.floor(Date.now() / 1000) + CODE_TTL_SECONDS,
    sub: session.email,
  });
  return redirectToClient(request.redirectUri, { code, state: request.state });
}

interface AuthorizeRequest {
  clientId: string;
  client: RegisteredClient;
  redirectUri: string;
  state?: string;
  codeChallenge: string;
  scopes: ApiScope[];
}

async function parseAuthorizeParams(
  env: Env,
  params: URLSearchParams,
): Promise<AuthorizeRequest | { error: string }> {
  const clientId = params.get("client_id")?.trim() ?? "";
  if (!clientId) return { error: "client_id is required" };
  const client = await verifyClient(env, clientId);
  if (!client) return { error: "unknown or malformed client_id — register the client first" };

  if ((params.get("response_type") ?? "").trim() !== "code") {
    return { error: "response_type must be 'code'" };
  }

  const redirectUri = params.get("redirect_uri")?.trim() ?? "";
  // Exact match against what was registered. A prefix or origin match is the
  // classic way an authorization code ends up at an attacker's endpoint.
  if (!redirectUri || !client.r.includes(redirectUri)) {
    return { error: "redirect_uri does not match this client's registration" };
  }

  const codeChallenge = params.get("code_challenge")?.trim() ?? "";
  const method = (params.get("code_challenge_method") ?? "").trim();
  if (!codeChallenge) return { error: "code_challenge is required (PKCE)" };
  if (method !== "S256") return { error: "code_challenge_method must be S256" };
  if (!/^[A-Za-z0-9_-]{43}$/.test(codeChallenge)) {
    return { error: "code_challenge must be a base64url-encoded SHA-256 digest" };
  }

  const state = params.get("state")?.trim() || undefined;
  return { clientId, client, redirectUri, state, codeChallenge, scopes: requestedScopes(params) };
}

/// A client may ask for less than the producer preset; it may never ask for
/// more. An empty or unrecognised request grants the whole preset, which is
/// what every current client sends.
function requestedScopes(params: URLSearchParams): ApiScope[] {
  const raw = params.get("scope")?.trim();
  if (!raw) return [...GRANTABLE_SCOPES];
  // Through `canonicalScope`, so a client that hardcoded a scope name from
  // before it was renamed asks for the thing it means rather than being
  // silently dropped and falling back to the full grant.
  const asked = new Set(raw.split(/\s+/).map(canonicalScope));
  const granted = GRANTABLE_SCOPES.filter((scope) => asked.has(scope));
  return granted.length > 0 ? granted : [...GRANTABLE_SCOPES];
}

function redirectToClient(redirectUri: string, params: Record<string, string | undefined>): Response {
  const url = new URL(redirectUri);
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) url.searchParams.set(key, value);
  }
  return new Response(null, {
    status: 303,
    headers: { Location: url.toString(), "cache-control": "no-store" },
  });
}

// ---------- Token ----------

export async function handleToken(req: Request, env: Env): Promise<Response> {
  if (!mcpConfigured(env)) return json({ error: "not found" }, 404);
  const limited = await enforceRateLimits(env, [
    { policy: "mcpTokenIpHour", key: clientIpKey(req) },
  ]);
  if (limited) return limited;

  let form: FormData;
  try {
    form = await readFormBody(req);
  } catch {
    return oauthError("invalid_request", "malformed form body");
  }

  if (String(form.get("grant_type") ?? "") !== "authorization_code") {
    return oauthError("unsupported_grant_type", "only authorization_code is supported");
  }
  const rawCode = String(form.get("code") ?? "").trim();
  const clientId = String(form.get("client_id") ?? "").trim();
  const redirectUri = String(form.get("redirect_uri") ?? "").trim();
  const verifier = String(form.get("code_verifier") ?? "").trim();
  if (!rawCode || !clientId || !verifier) {
    return oauthError("invalid_request", "code, client_id and code_verifier are required");
  }

  const code = await verifyCode(env, rawCode);
  if (!code) return oauthError("invalid_grant", "authorization code is invalid or expired");
  if (!constantTimeEqual(code.cid, clientId)) {
    return oauthError("invalid_grant", "authorization code was issued to another client");
  }
  if (redirectUri && redirectUri !== code.ru) {
    return oauthError("invalid_grant", "redirect_uri does not match the authorization request");
  }
  if (!constantTimeEqual(await pkceChallenge(verifier), code.cc)) {
    return oauthError("invalid_grant", "code_verifier does not match code_challenge");
  }
  // Last, and only once everything else about the code has checked out: a
  // failed exchange must not burn a code the legitimate client is still going
  // to present. Claiming is the same act as checking, so a concurrent retry
  // cannot have both requests find the code unused.
  if (!(await claimAuthorizationCode(env, code))) {
    return oauthError("invalid_grant", "authorization code has already been redeemed");
  }

  const client = await verifyClient(env, code.cid);
  let created: Awaited<ReturnType<typeof createApiKey>>;
  try {
    created = await createApiKey(env, {
      tenantId: code.tid,
      label: mcpCredentialLabel(client?.n, code.sub),
      purpose: "connector",
      scopes: code.sc,
    });
  } catch (err) {
    return oauthError(
      "invalid_grant",
      err instanceof Error ? err.message : "could not issue a credential",
    );
  }

  const expiresIn = Math.max(
    1,
    Math.floor((Date.parse(created.apiKey.expiresAt) - Date.now()) / 1000),
  );
  return json(
    {
      access_token: created.token,
      token_type: "Bearer",
      // No refresh token. The credential is a normal 00Widget API token whose
      // 90-day deadline slides forward on every authenticated call, so a
      // connector in use never expires and one abandoned for 90 days should
      // have to be re-approved by a human rather than silently renewed.
      expires_in: expiresIn,
      scope: created.apiKey.scopes.join(" "),
    },
    200,
    { "cache-control": "no-store", pragma: "no-cache" },
  );
}

/// Names the client and who approved it, so the admin key list says where a
/// credential came from. Bounded to the column's field limit.
function mcpCredentialLabel(clientName: string | undefined, approvedBy: string): string {
  return `MCP · ${clientName ?? "client"} · ${approvedBy}`.slice(0, FieldLimits.apiKeyLabel);
}

// ---------- Signed values ----------

async function signClient(env: Env, client: RegisteredClient): Promise<string> {
  const payload = b64url(JSON.stringify(client));
  const sig = await hmacSha256Hex(env.SESSION_SECRET!, `${CLIENT_SIGNING_PURPOSE}:${payload}`);
  return `${CLIENT_ID_PREFIX}${payload}.${sig}`;
}

async function verifyClient(env: Env, clientId: string): Promise<RegisteredClient | null> {
  if (!clientId.startsWith(CLIENT_ID_PREFIX)) return null;
  const [payload, sig] = clientId.slice(CLIENT_ID_PREFIX.length).split(".");
  if (!payload || !sig) return null;
  const expected = await hmacSha256Hex(env.SESSION_SECRET!, `${CLIENT_SIGNING_PURPOSE}:${payload}`);
  if (!constantTimeEqual(sig, expected)) return null;
  try {
    const parsed = JSON.parse(b64urlDecodeToText(payload)) as RegisteredClient;
    if (!parsed || typeof parsed.n !== "string" || !Array.isArray(parsed.r)) return null;
    return parsed;
  } catch {
    return null;
  }
}

async function signCode(env: Env, code: AuthorizationCode): Promise<string> {
  const payload = b64url(JSON.stringify(code));
  const sig = await hmacSha256Hex(env.SESSION_SECRET!, `${CODE_SIGNING_PURPOSE}:${payload}`);
  return `${payload}.${sig}`;
}

async function verifyCode(env: Env, raw: string): Promise<AuthorizationCode | null> {
  const [payload, sig] = raw.split(".");
  if (!payload || !sig) return null;
  const expected = await hmacSha256Hex(env.SESSION_SECRET!, `${CODE_SIGNING_PURPOSE}:${payload}`);
  if (!constantTimeEqual(sig, expected)) return null;
  let parsed: AuthorizationCode;
  try {
    parsed = JSON.parse(b64urlDecodeToText(payload)) as AuthorizationCode;
  } catch {
    return null;
  }
  if (!parsed || typeof parsed.exp !== "number") return null;
  if (parsed.exp * 1000 <= Date.now()) return null;
  if (!Array.isArray(parsed.sc)) return null;
  return parsed;
}

/// Records this code as redeemed, or reports that it already was.
///
/// `INSERT OR IGNORE` on the primary key makes the check and the claim one
/// statement, so two simultaneous exchanges cannot both find it unused. A code
/// with no `jti` is one issued before this existed: those are accepted, because
/// they expire 60 seconds after they were minted and refusing them would break
/// an exchange already in flight during a deploy.
async function claimAuthorizationCode(env: Env, code: AuthorizationCode): Promise<boolean> {
  if (typeof code.jti !== "string" || !code.jti) return true;
  const result = await env.ZW_DB.prepare(
    `INSERT OR IGNORE INTO mcp_authorization_codes (jti, redeemed_at, expires_at)
     VALUES (?, ?, ?)`,
  )
    .bind(code.jti, new Date().toISOString(), code.exp)
    .run();
  const claimed = (result.meta as { changes?: number } | undefined)?.changes !== 0;
  // Opportunistic and bounded, in the manner of the guest-credential prune.
  // A code lives 60 seconds, so this table is only ever a few rows deep and
  // there is no cron trigger to spare for it.
  if (claimed) await sweepRedeemedAuthorizationCodes(env);
  return claimed;
}

/// Drops rows whose codes can no longer be presented. Failure is swallowed:
/// housekeeping must never fail a token exchange that has already succeeded.
async function sweepRedeemedAuthorizationCodes(env: Env): Promise<void> {
  try {
    await env.ZW_DB.prepare(
      `DELETE FROM mcp_authorization_codes WHERE rowid IN (
         SELECT rowid FROM mcp_authorization_codes WHERE expires_at < ? LIMIT 100
       )`,
    )
      .bind(Math.floor(Date.now() / 1000))
      .run();
  } catch (err) {
    console.warn("mcp_authorization_code.sweep_failed", {
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

async function pkceChallenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return b64urlFromBytes(new Uint8Array(digest));
}

function b64urlFromBytes(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// ---------- Rendering ----------

function consentResponse(html: string, redirectUri: string): Response {
  // Approving is a same-origin POST that answers with a 303 to the client's
  // callback. Chrome applies `form-action` to every redirect in that
  // navigation, including redirects made *by* the callback. Listing only the
  // registered callback origin therefore breaks clients whose callback hands
  // off to another HTTPS origin (the OpenAI developer portal does this).
  //
  // Keep the form itself on this origin and allow the HTTPS redirect chain.
  // Local MCP clients are the one permitted HTTP exception, so preserve their
  // exact registered loopback origin rather than allowing arbitrary HTTP.
  const redirect = new URL(redirectUri);
  const formAction = redirect.protocol === "http:"
    ? `'self' https: ${redirect.origin}`
    : "'self' https:";
  return new Response(html, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": [
        "default-src 'none'",
        "base-uri 'none'",
        `form-action ${formAction}`,
        "frame-ancestors 'none'",
        "object-src 'none'",
        "style-src 'unsafe-inline'",
      ].join("; "),
      // See the note in html.ts: no-referrer nulls the Origin header on the
      // form POST this page makes, which the CSRF check then rejects.
      "referrer-policy": "same-origin",
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY",
    },
  });
}

function renderConsentPage(
  request: AuthorizeRequest,
  session: WebPrincipal,
): string {
  const hidden = [
    ["response_type", "code"],
    ["client_id", request.clientId],
    ["redirect_uri", request.redirectUri],
    ["code_challenge", request.codeChallenge],
    ["code_challenge_method", "S256"],
    ["scope", request.scopes.join(" ")],
    ...(request.state ? [["state", request.state]] : []),
    ["csrf", session.csrf],
  ]
    .map(([name, value]) => `<input type="hidden" name="${esc(name)}" value="${esc(value)}">`)
    .join("\n         ");

  return baseHTML(
    "00Widget · Connect an MCP client",
    `<header><h1>00Widget · Connect</h1><div class="meta">signed in as ${esc(session.email)}</div></header>
     <section>
       <h2>${esc(request.client.n)} wants to publish to 00Widget</h2>
       <p>${esc(request.client.n)} can <strong>read</strong> your cards and activities and
       <strong>publish</strong> to them.</p>
       <div class="oauth-detail">
         <span class="oauth-detail-label">Redirects to</span>
         <code>${esc(request.redirectUri)}</code>
       </div>
       <form method="post" action="${esc(AUTHORIZE_PATH)}">
         ${hidden}
         <p class="actions">
           <button class="button button-secondary" type="submit" name="decision" value="deny">Deny</button>
           <button class="button" type="submit" name="decision" value="approve">Approve</button>
         </p>
       </form>
     </section>`,
  );
}

/// Signed in, but nothing to publish to. Reachable by an administrator whose
/// own address owns no tenant, and by the API-token bootstrap session, which
/// has no identity at all.
function renderNoTenantError(session: WebPrincipal): string {
  return baseHTML(
    "00Widget · Connect",
    `<header><h1>00Widget · Connect</h1></header>
     <section>
       <h2>No account to connect</h2>
       <p>${esc(session.email)} does not own a 00Widget account, so there is nothing for this
       client to publish to. Sign in to the iOS app with this Apple ID first.</p>
     </section>`,
  );
}

function renderAuthorizeError(message: string): string {
  return baseHTML(
    "00Widget · Connect",
    `<header><h1>00Widget · Connect</h1></header>
     <section><h2>Cannot authorize</h2><p class="error">${esc(message)}</p></section>`,
  );
}

// ---------- Small helpers ----------

function oauthError(error: string, description: string): Response {
  const status = error === "invalid_client" ? 401 : 400;
  return json({ error, error_description: description }, status, { "cache-control": "no-store" });
}

/// https for anything remote; http only for loopback, which is how a locally
/// running MCP client receives its callback. Fragments are forbidden by
/// RFC 6749 and would silently swallow the code.
function isAllowedRedirectUri(value: string): boolean {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.hash) return false;
  if (url.protocol === "https:") return true;
  return url.protocol === "http:"
    && (url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]");
}

/// See the note on `loginIpKey` in webLogin.ts: only the header Cloudflare
/// sets, never the one the caller sends.
function clientIpKey(req: Request): string {
  const cfIp = req.headers.get("cf-connecting-ip")?.trim();
  return `mcp-oauth:${cfIp || "unknown"}`;
}

function formEntries(form: FormData): [string, string][] {
  const entries: [string, string][] = [];
  for (const [key, value] of form.entries()) {
    if (typeof value === "string") entries.push([key, value]);
  }
  return entries;
}

async function readJsonBody(req: Request): Promise<unknown> {
  return JSON.parse(await readBodyText(req));
}

async function readFormBody(req: Request): Promise<FormData> {
  const text = await readBodyText(req);
  const contentType = req.headers.get("content-type") ?? "application/x-www-form-urlencoded";
  return await new Response(text, { headers: { "content-type": contentType } }).formData();
}

async function readBodyText(req: Request): Promise<string> {
  const contentLength = req.headers.get("content-length")?.trim();
  if (contentLength && /^\d+$/.test(contentLength) && Number(contentLength) > OAUTH_BODY_MAX_BYTES) {
    throw new Error("body too large");
  }
  const text = await req.text();
  if (text.length > OAUTH_BODY_MAX_BYTES) throw new Error("body too large");
  return text;
}
