import {
  ApiScopePresets,
  createApiKey,
  sha256Hex,
  type AuthContext,
} from "./auth";
import { parseJson } from "./cards";
import { baseHTML, esc, htmlResponse } from "./html";
import { badRequest, json, notFound } from "./http";
import {
  enforceRateLimits,
  tenantKey,
} from "./rateLimit";
import {
  redirectToSignIn,
  requireWebMutationSession,
  requireWebSession,
  resolveWebTenantIdentity,
} from "./webSession";
import { RequestBodyLimits, type Env } from "./types";

const DEVICE_CODE_TTL_SECONDS = 10 * 60;
const POLL_INTERVAL_SECONDS = 5;
const USER_CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
const USER_CODE_LENGTH = 8;
const DEVICE_CODE_BYTES = 32;

type DeviceAuthorizationStatus =
  | "pending"
  | "approved"
  | "denied"
  | "consuming"
  | "consumed";

interface DeviceAuthorizationRow {
  id: string;
  status: DeviceAuthorizationStatus;
  tenant_id: string | null;
  expires_at: string;
}

interface DeviceTokenRequest {
  device_code?: string;
}

interface DeviceApprovalRequest {
  user_code?: string;
  // Compatibility with the first iOS beta, whose local Codable body used
  // Swift's property name before it gained an explicit snake-case key.
  userCode?: string;
}

export function deviceAuthorizationEnabled(env: Env): boolean {
  return env.HORIZON_DEVICE_AUTH_ENABLED === "true";
}

/// POST /v1/auth/device/code
///
/// Starts a short-lived RFC 8628-style device authorization. The short code is
/// safe to display and place in the verification URL; the device code is the
/// bearer secret and is returned only to the headset.
export async function createDeviceAuthorization(req: Request, env: Env): Promise<Response> {
  if (!deviceAuthorizationEnabled(env)) return notFound();
  const limited = await enforceRateLimits(env, [
    { policy: "deviceCodeIpHour", key: requestIpKey(req) },
  ]);
  if (limited) return limited;

  const now = new Date();
  const expiresAt = new Date(now.getTime() + DEVICE_CODE_TTL_SECONDS * 1000);
  const deviceCode = randomUrlToken(DEVICE_CODE_BYTES);
  const userCode = randomUserCode();
  const normalizedUserCode = normalizeUserCode(userCode)!;

  await env.ZW_DB.prepare(
    `INSERT INTO device_authorizations
       (id, device_code_hash, user_code_hash, status, tenant_id, created_at, expires_at,
        approved_at, consumed_at)
     VALUES (?, ?, ?, 'pending', NULL, ?, ?, NULL, NULL)`,
  )
    .bind(
      crypto.randomUUID(),
      await sha256Hex(deviceCode),
      await sha256Hex(normalizedUserCode),
      now.toISOString(),
      expiresAt.toISOString(),
    )
    .run();

  await sweepExpiredDeviceAuthorizations(env, now);

  const origin = new URL(req.url).origin;
  const verificationUri = `${origin}/device`;
  const verificationUriComplete = `${origin}/app/device?code=${encodeURIComponent(userCode)}`;
  return json({
    device_code: deviceCode,
    user_code: userCode,
    verification_uri: verificationUri,
    verification_uri_complete: verificationUriComplete,
    expires_in: DEVICE_CODE_TTL_SECONDS,
    interval: POLL_INTERVAL_SECONDS,
  }, 201, { "cache-control": "no-store" });
}

/// POST /v1/auth/device/token
///
/// The Horizon client polls this at the server-advised interval. Pending and
/// terminal states intentionally use a 200 response because the existing
/// constrained-device client decodes the RFC state from the JSON body.
export async function exchangeDeviceAuthorization(req: Request, env: Env): Promise<Response> {
  if (!deviceAuthorizationEnabled(env)) return notFound();
  if (!(await sourceRateLimitAllows(env, `device-token:${requestIpKey(req)}`))) {
    return json({ error: "slow_down" }, 200, { "cache-control": "no-store" });
  }

  let input: DeviceTokenRequest;
  try {
    input = (await parseJson(req, RequestBodyLimits.deviceAuth)) as DeviceTokenRequest;
  } catch {
    return badRequest("missing JSON body");
  }
  const deviceCode = input?.device_code?.trim();
  if (!deviceCode || deviceCode.length > 256) return badRequest("device_code is required");

  const hash = await sha256Hex(deviceCode);
  const row = await env.ZW_DB.prepare(
    `SELECT id, status, tenant_id, expires_at
     FROM device_authorizations
     WHERE device_code_hash = ?`,
  )
    .bind(hash)
    .first<DeviceAuthorizationRow>();
  if (!row) return deviceState("expired");
  if (Date.parse(row.expires_at) <= Date.now()) return deviceState("expired");
  if (row.status === "pending") return deviceState("authorization_pending");
  if (row.status === "denied") return deviceState("denied");
  if (row.status !== "approved" || !row.tenant_id) return deviceState("expired");

  // Claim before minting so two concurrent polls cannot both receive a new
  // credential. If minting fails, put it back so a transient D1 failure does
  // not permanently burn an otherwise valid approval.
  const claimed = await env.ZW_DB.prepare(
    `UPDATE device_authorizations
     SET status = 'consuming'
     WHERE id = ? AND status = 'approved'`,
  )
    .bind(row.id)
    .run();
  if (changedRows(claimed) === 0) return deviceState("authorization_pending");

  try {
    const created = await createApiKey(env, {
      tenantId: row.tenant_id,
      label: "Horizon OS",
      // Horizon is a first-party 00Widget app, not a publisher integration.
      // Keep its capabilities narrowed with the device scope preset while
      // identifying the credential as app-owned for app-only account routes.
      //
      // `kind` is not narrowed by `scopes`: the app-only account routes in
      // index.ts pass a `null` requiredScope, so being kind `app` is the
      // whole of their gate. This credential therefore also reaches
      // GET /v1/account, the two mcp-connections routes, agent-token
      // rotation, device approval, and DELETE /v1/account — the last three
      // of which Horizon never calls. Both consent strings (the approval
      // page below and DeviceAuthorizationApprovalView on iOS) describe
      // that whole set and have to move with it.
      kind: "app",
      purpose: "device",
      scopes: ApiScopePresets.device,
    });
    await env.ZW_DB.prepare(
      `UPDATE device_authorizations
       SET status = 'consumed', consumed_at = ?
       WHERE id = ? AND status = 'consuming'`,
    )
      .bind(new Date().toISOString(), row.id)
      .run();
    return json({ token: created.token }, 200, { "cache-control": "no-store" });
  } catch (error) {
    try {
      await env.ZW_DB.prepare(
        `UPDATE device_authorizations
         SET status = 'approved'
         WHERE id = ? AND status = 'consuming'`,
      )
        .bind(row.id)
        .run();
    } catch {
      // The original error is the useful one; the row expires in minutes.
    }
    throw error;
  }
}

/// POST /v1/auth/device/approve — native iOS path, app credential only.
export async function approveDeviceAuthorizationFromApp(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  if (!deviceAuthorizationEnabled(env)) return notFound();
  let input: DeviceApprovalRequest;
  try {
    input = (await parseJson(req, RequestBodyLimits.deviceAuth)) as DeviceApprovalRequest;
  } catch {
    return badRequest("missing JSON body");
  }
  const limited = await enforceRateLimits(env, [
    { policy: "deviceApproveTenantHour", key: tenantKey(auth.tenantId) },
  ], auth);
  if (limited) return limited;
  return approvalJson(await approveByUserCode(
    env,
    input?.user_code ?? input?.userCode,
    auth.tenantId,
  ));
}

/// GET /device — manual fallback shown by the Horizon client when the Login API
/// is unavailable. Submitting it enters the same Universal Link/browser route.
export function renderDeviceCodeEntry(_req: Request, env: Env): Response {
  if (!deviceAuthorizationEnabled(env)) return notFound();
  return htmlResponse(baseHTML(
    "00Widget · Connect Horizon OS",
    `<header><h1>00Widget · Connect Horizon OS</h1></header>
     <section class="login">
       <h2>Enter the code shown in your headset</h2>
       <form method="get" action="/app/device">
         <label for="code">Connection code</label>
         <input id="code" name="code" autocomplete="one-time-code" required
                maxlength="12" autocapitalize="characters">
         <button class="button" type="submit">Continue</button>
       </form>
     </section>`,
  ));
}

/// GET /app/device?code=… — browser fallback when the Universal Link is not
/// claimed by an installed iOS app.
export async function renderDeviceApproval(req: Request, env: Env): Promise<Response> {
  if (!deviceAuthorizationEnabled(env)) return notFound();
  const code = new URL(req.url).searchParams.get("code");
  const state = await authorizationByUserCode(env, code);
  if ("error" in state) return approvalErrorPage(state.error, state.status);

  const session = await requireWebSession(req, env);
  if (!session) return redirectToSignIn(req);
  const identity = await resolveWebTenantIdentity(env, session);
  if (!identity) {
    return approvalErrorPage("This Apple identity does not have a 00Widget account.", 403);
  }
  const displayCode = formatUserCode(normalizeUserCode(code)!);
  return htmlResponse(baseHTML(
    "00Widget · Approve Horizon OS",
    `<header><h1>00Widget · Connect Horizon OS</h1><div class="meta">signed in as ${esc(session.email)}</div></header>
     <section class="login">
       <h2>Connect the headset showing <code>${esc(displayCode)}</code>?</h2>
       <p class="muted">This headset will be able to read your dashboard, run its safe actions, and manage your account — including your connected agents and deleting the account. It cannot publish widgets.</p>
       <form method="post" action="/app/device?code=${encodeURIComponent(displayCode)}">
         <input type="hidden" name="csrf" value="${esc(session.csrf)}">
         <input type="hidden" name="code" value="${esc(displayCode)}">
         <p class="actions">
           <button class="button button-secondary" type="submit" name="decision" value="deny">Deny</button>
           <button class="button" type="submit" name="decision" value="approve">Connect headset</button>
         </p>
       </form>
     </section>`,
  ));
}

/// POST /app/device?code=… — browser approval after Sign in with Apple.
export async function handleDeviceApprovalDecision(req: Request, env: Env): Promise<Response> {
  if (!deviceAuthorizationEnabled(env)) return notFound();
  const session = await requireWebMutationSession(req, env);
  if (session instanceof Response) return session;
  const identity = await resolveWebTenantIdentity(env, session);
  if (!identity) return approvalErrorPage("This Apple identity does not have a 00Widget account.", 403);

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return approvalErrorPage("The approval form was malformed.", 400);
  }
  const limited = await enforceRateLimits(env, [
    { policy: "deviceApproveTenantHour", key: tenantKey(identity.tenantId) },
  ], session);
  if (limited) return limited;

  const code = String(form.get("code") ?? new URL(req.url).searchParams.get("code") ?? "");
  const decision = String(form.get("decision") ?? "");
  if (decision === "deny") {
    const denied = await denyByUserCode(env, code);
    if ("error" in denied) return approvalErrorPage(denied.error, denied.status);
    return completionPage("Connection denied", "The headset was not connected.");
  }
  if (decision !== "approve") return approvalErrorPage("Choose Connect or Deny.", 400);

  const outcome = await approveByUserCode(env, code, identity.tenantId);
  if ("error" in outcome) return approvalErrorPage(outcome.error, outcome.status);
  return completionPage("Headset connected", "Return to your headset to finish signing in.");
}

async function approveByUserCode(
  env: Env,
  rawCode: string | undefined | null,
  tenantId: string,
): Promise<{ ok: true } | { error: string; status: number }> {
  const code = normalizeUserCode(rawCode);
  if (!code) return { error: "That connection code is malformed.", status: 400 };
  const hash = await sha256Hex(code);
  const row = await env.ZW_DB.prepare(
    `SELECT id, status, tenant_id, expires_at
     FROM device_authorizations
     WHERE user_code_hash = ?`,
  )
    .bind(hash)
    .first<DeviceAuthorizationRow>();
  if (!row) return { error: "That connection code is invalid.", status: 404 };
  if (Date.parse(row.expires_at) <= Date.now()) {
    return { error: "That connection code has expired. Start again on the headset.", status: 410 };
  }
  if (row.status === "approved" && row.tenant_id === tenantId) return { ok: true };
  if (row.status !== "pending") {
    return { error: "That connection code has already been used.", status: 409 };
  }
  const updated = await env.ZW_DB.prepare(
    `UPDATE device_authorizations
     SET status = 'approved', tenant_id = ?, approved_at = ?
     WHERE id = ? AND status = 'pending'`,
  )
    .bind(tenantId, new Date().toISOString(), row.id)
    .run();
  if (changedRows(updated) === 0) {
    return { error: "That connection code has already been used.", status: 409 };
  }
  return { ok: true };
}

async function denyByUserCode(
  env: Env,
  rawCode: string | undefined | null,
): Promise<{ ok: true } | { error: string; status: number }> {
  const code = normalizeUserCode(rawCode);
  if (!code) return { error: "That connection code is malformed.", status: 400 };
  const row = await env.ZW_DB.prepare(
    `SELECT id, status, tenant_id, expires_at
     FROM device_authorizations
     WHERE user_code_hash = ?`,
  )
    .bind(await sha256Hex(code))
    .first<DeviceAuthorizationRow>();
  if (!row) return { error: "That connection code is invalid.", status: 404 };
  if (Date.parse(row.expires_at) <= Date.now()) {
    return { error: "That connection code has expired.", status: 410 };
  }
  if (row.status !== "pending") {
    return { error: "That connection code has already been used.", status: 409 };
  }
  await env.ZW_DB.prepare(
    `UPDATE device_authorizations SET status = 'denied' WHERE id = ? AND status = 'pending'`,
  )
    .bind(row.id)
    .run();
  return { ok: true };
}

async function authorizationByUserCode(
  env: Env,
  rawCode: string | undefined | null,
): Promise<{ ok: true } | { error: string; status: number }> {
  const code = normalizeUserCode(rawCode);
  if (!code) return { error: "Enter the eight-character code shown in your headset.", status: 400 };
  const row = await env.ZW_DB.prepare(
    `SELECT id, status, tenant_id, expires_at
     FROM device_authorizations
     WHERE user_code_hash = ?`,
  )
    .bind(await sha256Hex(code))
    .first<DeviceAuthorizationRow>();
  if (!row) return { error: "That connection code is invalid.", status: 404 };
  if (Date.parse(row.expires_at) <= Date.now()) {
    return { error: "That connection code has expired. Start again on the headset.", status: 410 };
  }
  if (row.status !== "pending") {
    return { error: "That connection code has already been used.", status: 409 };
  }
  return { ok: true };
}

function approvalJson(outcome: { ok: true } | { error: string; status: number }): Response {
  return "error" in outcome
    ? json({ error: outcome.error }, outcome.status)
    : json({ ok: true });
}

function approvalErrorPage(message: string, status: number): Response {
  return htmlResponse(baseHTML(
    "00Widget · Connection problem",
    `<header><h1>00Widget · Connect Horizon OS</h1></header>
     <section class="login"><h2>Could not connect</h2><p class="error">${esc(message)}</p></section>`,
  ), status);
}

function completionPage(title: string, message: string): Response {
  return htmlResponse(baseHTML(
    `00Widget · ${title}`,
    `<header><h1>00Widget · Connect Horizon OS</h1></header>
     <section class="login"><h2>${esc(title)}</h2><p>${esc(message)}</p></section>`,
  ));
}

function deviceState(error: "authorization_pending" | "denied" | "expired"): Response {
  return json({ error }, 200, { "cache-control": "no-store" });
}

function normalizeUserCode(raw: string | undefined | null): string | null {
  if (!raw) return null;
  const normalized = raw.toUpperCase().replace(/[-\s]/g, "");
  if (normalized.length !== USER_CODE_LENGTH) return null;
  for (const char of normalized) {
    if (!USER_CODE_ALPHABET.includes(char)) return null;
  }
  return normalized;
}

function formatUserCode(normalized: string): string {
  return `${normalized.slice(0, 4)}-${normalized.slice(4)}`;
}

function randomUserCode(): string {
  const bytes = new Uint8Array(USER_CODE_LENGTH);
  crypto.getRandomValues(bytes);
  let code = "";
  for (const byte of bytes) code += USER_CODE_ALPHABET[byte % USER_CODE_ALPHABET.length];
  return formatUserCode(code);
}

function randomUrlToken(bytes: number): string {
  const data = new Uint8Array(bytes);
  crypto.getRandomValues(data);
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function requestIpKey(req: Request): string {
  return `ip:${req.headers.get("cf-connecting-ip")?.trim() || "unknown"}`;
}

async function sourceRateLimitAllows(env: Env, key: string): Promise<boolean> {
  try {
    return (await env.AUTH_SOURCE_LIMITER.limit({ key })).success;
  } catch (error) {
    console.warn("device authorization rate limiter unavailable", error);
    return true;
  }
}

function changedRows(result: D1Result): number {
  return (result.meta as { changes?: number } | undefined)?.changes ?? 0;
}

async function sweepExpiredDeviceAuthorizations(env: Env, now = new Date()): Promise<void> {
  try {
    await env.ZW_DB.prepare(
      `DELETE FROM device_authorizations WHERE rowid IN (
         SELECT rowid FROM device_authorizations WHERE expires_at < ? LIMIT 100
       )`,
    )
      .bind(now.toISOString())
      .run();
  } catch (error) {
    console.warn("device_authorization.sweep_failed", {
      error: error instanceof Error ? error.message : String(error),
    });
  }
}
