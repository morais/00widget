import { isSecureAdminSecret } from "./adminSecurity";
import { sha256Hex, type AuthContext } from "./auth";
import { parseJson } from "./cards";
import { getHorizonUserForTenant, horizonIdentityEnabled } from "./horizonIdentity";
import { baseHTML, esc, htmlResponse } from "./html";
import { badRequest, json, notFound } from "./http";
import { enforceRateLimits, tenantKey } from "./rateLimit";
import { makeSessionCookie, parseCookies, safeNextPath } from "./webSession";
import { RequestBodyLimits, type Env } from "./types";

const COOKIE_NAME = "zw_horizon_browser";
const LOGIN_TTL_SECONDS = 10 * 60;
const CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";

interface BrowserLoginRow {
  id: string;
  code_hash: string;
  status: "pending" | "approved" | "denied" | "consumed";
  app_id: string | null;
  user_id: string | null;
  tenant_id: string | null;
  next_path: string | null;
  expires_at: string;
}

function configured(env: Env): boolean {
  return horizonIdentityEnabled(env)
    && Boolean(env.META_APP_ID?.trim())
    && isSecureAdminSecret(env.SESSION_SECRET);
}

/// GET /login/horizon — a browser starts a ten-minute login and asks the
/// signed-in headset to approve the displayed code. The browser secret stays
/// in an HttpOnly cookie; the headset receives the short code alone.
export async function startHorizonBrowserLogin(req: Request, env: Env): Promise<Response> {
  if (!configured(env)) return notFound();
  const limited = await enforceRateLimits(env, [
    { policy: "horizonBrowserIpHour", key: `horizon-browser:${req.headers.get("cf-connecting-ip")?.trim() || "unknown"}` },
  ]);
  if (limited) return limited;

  const code = randomCode();
  const secret = randomUrlToken(32);
  const now = new Date();
  const next = safeNextPath(new URL(req.url).searchParams.get("next")) ?? null;
  await env.ZW_DB.prepare(
    `INSERT INTO horizon_browser_logins
       (id, code_hash, browser_hash, status, app_id, user_id, tenant_id,
        next_path, created_at, expires_at)
     VALUES (?, ?, ?, 'pending', NULL, NULL, NULL, ?, ?, ?)`,
  ).bind(
    crypto.randomUUID(),
    await sha256Hex(normalizeCode(code)!),
    await sha256Hex(secret),
    next,
    now.toISOString(),
    new Date(now.getTime() + LOGIN_TTL_SECONDS * 1000).toISOString(),
  ).run();
  await env.ZW_DB.prepare(`DELETE FROM horizon_browser_logins WHERE expires_at < ?`)
    .bind(now.toISOString()).run();

  const response = htmlResponse(codePage(code, false));
  response.headers.set("cache-control", "no-store");
  response.headers.append(
    "set-cookie",
    `${COOKIE_NAME}=${secret}.${normalizeCode(code)}; Path=/login/horizon; Max-Age=${LOGIN_TTL_SECONDS}; HttpOnly; Secure; SameSite=Lax`,
  );
  return response;
}

/// GET /login/horizon/complete — manual polling keeps the page usable without
/// JavaScript. Approval exchanges the browser-bound code for an ordinary web
/// session, which MCP OAuth already knows how to use for consent.
export async function completeHorizonBrowserLogin(req: Request, env: Env): Promise<Response> {
  if (!configured(env)) return notFound();
  const raw = parseCookies(req.headers.get("cookie"))[COOKIE_NAME] ?? "";
  const [secret, shownCode] = raw.split(".");
  if (!secret || !shownCode) return problem("Start a Horizon browser sign-in again.", 400);
  const row = await env.ZW_DB.prepare(
    `SELECT id, code_hash, status, app_id, user_id, tenant_id, next_path, expires_at
     FROM horizon_browser_logins WHERE browser_hash = ?`,
  ).bind(await sha256Hex(secret)).first<BrowserLoginRow>();
  if (!row || Date.parse(row.expires_at) <= Date.now()
    || await sha256Hex(shownCode) !== row.code_hash) {
    return problem("This sign-in code has expired. Start again.", 410);
  }
  if (row.status === "pending") {
    const response = htmlResponse(codePage(formatCode(shownCode), true));
    response.headers.set("cache-control", "no-store");
    return response;
  }
  if (row.status === "denied") return problem("The headset denied this sign-in.", 403);
  if (row.status !== "approved" || !row.app_id || !row.user_id || !row.tenant_id) {
    return problem("This sign-in code has already been used.", 410);
  }

  const consumed = await env.ZW_DB.prepare(
    `UPDATE horizon_browser_logins SET status = 'consumed' WHERE id = ? AND status = 'approved'`,
  ).bind(row.id).run();
  if (changedRows(consumed) === 0) return problem("This sign-in code has already been used.", 410);

  const session = await makeSessionCookie(env, "Horizon account", "horizon", {
    horizonAppId: row.app_id,
    horizonUserId: row.user_id,
    tenantId: row.tenant_id,
  });
  const headers = new Headers({
    location: safeNextPath(row.next_path) ?? "/",
    "cache-control": "no-store",
  });
  headers.append("set-cookie", session);
  headers.append("set-cookie", `${COOKIE_NAME}=; Path=/login/horizon; Max-Age=0; HttpOnly; Secure; SameSite=Lax`);
  return new Response(null, { status: 302, headers });
}

/// POST /v1/auth/horizon/browser/approve — called with the headset's app
/// credential. The code never chooses a tenant; its verified Meta identity
/// mapping does, and the resulting web session is revalidated on every read.
export async function approveHorizonBrowserLogin(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  if (!configured(env)) return notFound();
  let input: { code?: unknown; decision?: unknown };
  try {
    input = (await parseJson(req, RequestBodyLimits.horizonBrowserApproval)) as typeof input;
  } catch {
    return badRequest("missing JSON body");
  }
  const code = normalizeCode(input?.code);
  if (!code) return badRequest("code is malformed");
  if (input.decision !== undefined && input.decision !== "approve" && input.decision !== "deny") {
    return badRequest("decision must be approve or deny");
  }
  const limited = await enforceRateLimits(env, [
    { policy: "horizonBrowserApproveTenantHour", key: tenantKey(auth.tenantId) },
  ], auth);
  if (limited) return limited;

  const appId = env.META_APP_ID!.trim();
  const userId = await getHorizonUserForTenant(env, auth.tenantId);
  if (!userId) return json({ error: "Horizon identity is not linked to this account" }, 403);
  const row = await env.ZW_DB.prepare(
    `SELECT id, code_hash, status, app_id, user_id, tenant_id, next_path, expires_at
     FROM horizon_browser_logins WHERE code_hash = ?`,
  ).bind(await sha256Hex(code)).first<BrowserLoginRow>();
  if (!row || Date.parse(row.expires_at) <= Date.now()) {
    return json({ error: "Code is invalid or expired" }, 404);
  }
  if (row.status !== "pending") return json({ error: "Code has already been used" }, 409);

  const decision = input.decision === "deny" ? "denied" : "approved";
  const updated = await env.ZW_DB.prepare(
    `UPDATE horizon_browser_logins
     SET status = ?, app_id = ?, user_id = ?, tenant_id = ?
     WHERE id = ? AND status = 'pending'`,
  ).bind(decision, appId, userId, auth.tenantId, row.id).run();
  return changedRows(updated) === 0
    ? json({ error: "Code has already been used" }, 409)
    : json({ ok: true, status: decision });
}

function codePage(code: string, waiting: boolean): string {
  return baseHTML(
    "00Widget · Sign in with Horizon",
    `<header><h1>00Widget · Horizon sign-in</h1></header>
     <section class="login">
       <h2>${waiting ? "Waiting for your headset" : "Confirm this code in your headset"}</h2>
       <p>Open 00Widget on Horizon OS and approve browser sign-in for:</p>
       <p><code>${esc(code)}</code></p>
       <p class="muted">Only approve if this code matches the one shown here. It expires in ten minutes.</p>
       <a class="button" href="/login/horizon/complete">Check connection</a>
     </section>`,
  );
}

function problem(message: string, status: number): Response {
  const response = htmlResponse(baseHTML(
    "00Widget · Horizon sign-in",
    `<header><h1>00Widget · Horizon sign-in</h1></header>
     <section class="login"><h2>Could not sign in</h2><p>${esc(message)}</p></section>`,
  ), status);
  response.headers.set("cache-control", "no-store");
  return response;
}

function normalizeCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const code = raw.toUpperCase().replace(/[-\s]/g, "");
  return code.length === 8 && [...code].every((char) => CODE_ALPHABET.includes(char)) ? code : null;
}

function formatCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

function randomCode(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return formatCode([...bytes].map((byte) => CODE_ALPHABET[byte % CODE_ALPHABET.length]).join(""));
}

function randomUrlToken(bytes: number): string {
  const data = new Uint8Array(bytes);
  crypto.getRandomValues(data);
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function changedRows(result: D1Result): number {
  return (result.meta as { changes?: number } | undefined)?.changes ?? 0;
}
