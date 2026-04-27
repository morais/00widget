import type { Env } from "./types";
import {
  appleSignInConfigured,
  buildAuthorizeURL,
  clearSessionCookie,
  isAdminEmail,
  makeSessionCookie,
  randomToken,
  readSessionCookie,
  validateAppleIdToken,
} from "./appleAuth";
import * as storage from "./storage";

const STATE_COOKIE = "zw_admin_state";
const NONCE_COOKIE = "zw_admin_nonce";

// ---------- Routes ----------

export async function handleAdminLogin(_req: Request, env: Env): Promise<Response> {
  if (!appleSignInConfigured(env)) {
    return htmlResponse(renderConfigError(env), 500);
  }
  const state = randomToken();
  const nonce = randomToken();
  const url = buildAuthorizeURL(env, state, nonce);
  const headers = new Headers({ Location: url });
  headers.append("Set-Cookie", oauthCookie(STATE_COOKIE, state));
  headers.append("Set-Cookie", oauthCookie(NONCE_COOKIE, nonce));
  return new Response(null, { status: 302, headers });
}

export async function handleAdminCallback(req: Request, env: Env): Promise<Response> {
  if (!appleSignInConfigured(env)) return htmlResponse(renderConfigError(env), 500);

  const cookies = parseCookies(req.headers.get("cookie"));
  const expectedState = cookies[STATE_COOKIE];
  const expectedNonce = cookies[NONCE_COOKIE];

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return htmlResponse(renderError("missing form body"), 400);
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
  if (!isAdminEmail(env, claims.email)) {
    return htmlResponse(renderError(`${claims.email} is not in ADMIN_EMAILS`), 403);
  }

  const cookie = await makeSessionCookie(env, claims.email);
  const headers = new Headers({ Location: "/admin" });
  headers.append("Set-Cookie", cookie);
  headers.append("Set-Cookie", expireOauthCookie(STATE_COOKIE));
  headers.append("Set-Cookie", expireOauthCookie(NONCE_COOKIE));
  return new Response(null, { status: 302, headers });
}

export async function handleAdminLogout(_req: Request, _env: Env): Promise<Response> {
  const headers = new Headers({ Location: "/admin/login" });
  headers.append("Set-Cookie", clearSessionCookie());
  return new Response(null, { status: 302, headers });
}

export async function handleAdminDashboard(req: Request, env: Env): Promise<Response> {
  if (!appleSignInConfigured(env)) return htmlResponse(renderConfigError(env), 500);
  const session = await readSessionCookie(env, req);
  if (!session) {
    return new Response(null, { status: 302, headers: { Location: "/admin/login" } });
  }

  const [cards, devices, widgetTokens, activities, pending, startTokens] = await Promise.all([
    storage.listAllCards(env),
    storage.listAllDevices(env),
    storage.listAllWidgetTokens(env),
    storage.listAllActivities(env),
    storage.listAllPendingActivities(env),
    storage.listAllStartTokens(env),
  ]);

  return htmlResponse(
    renderDashboard({
      session,
      cards,
      devices,
      widgetTokens,
      activities,
      pending,
      startTokens,
    }),
  );
}

// ---------- HTML rendering ----------

interface DashboardData {
  session: { email: string; iat: number; exp: number };
  cards: storage.ScopedEntry<unknown>[];
  devices: storage.ScopedEntry<unknown>[];
  widgetTokens: storage.ScopedEntry<string>[];
  activities: storage.ScopedEntry<unknown>[];
  pending: storage.ScopedEntry<unknown>[];
  startTokens: storage.ScopedEntry<string>[];
}

function renderDashboard(d: DashboardData): string {
  return baseHTML(
    "00Widget · Admin",
    `
    <header>
      <h1>00Widget · Admin</h1>
      <div class="meta">
        Signed in as <strong>${esc(d.session.email)}</strong>
        · <a href="/admin/logout">log out</a>
      </div>
    </header>

    ${renderCardsSection(d.cards)}
    ${renderTokenSection("Devices", d.devices, ["device id", "apnsDeviceToken", "appVersion", "platform", "updatedAt"])}
    ${renderWidgetTokensSection(d.widgetTokens)}
    ${renderActivitiesSection(d.activities)}
    ${renderPendingSection(d.pending)}
    ${renderStartTokensSection(d.startTokens)}
    `,
  );
}

function renderCardsSection(cards: storage.ScopedEntry<unknown>[]): string {
  if (cards.length === 0) return section("Cards", "<p class=\"empty\">No cards published yet.</p>");
  const rows = cards.map((entry) => {
    const c = entry.value as Record<string, unknown>;
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(String(c.id ?? ""))}</code></td>
      <td>${esc(String(c.template ?? ""))}</td>
      <td>${esc(String(c.title ?? ""))}</td>
      <td><span class="status status-${esc(String(c.status ?? "unknown"))}">${esc(String(c.status ?? "unknown"))}</span></td>
      <td class="ts">${esc(String(c.updatedAt ?? ""))}</td>
      <td><details><summary>json</summary><pre>${esc(JSON.stringify(c, null, 2))}</pre></details></td>
    </tr>`;
  }).join("");
  return section(
    `Cards <span class="count">${cards.length}</span>`,
    `<table><thead><tr><th>API key</th><th>id</th><th>template</th><th>title</th><th>status</th><th>updatedAt</th><th>raw</th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderTokenSection(
  title: string,
  entries: storage.ScopedEntry<unknown>[],
  fields: string[],
): string {
  if (entries.length === 0) return section(title, `<p class="empty">None registered.</p>`);
  const rows = entries.map((entry) => {
    const v = entry.value as Record<string, unknown>;
    const cells = fields
      .map((f) => {
        if (f === "device id") return `<td><code>${esc(entry.key.split(":").slice(2).join(":"))}</code></td>`;
        const raw = v[f];
        return `<td>${esc(raw == null ? "" : truncate(String(raw)))}</td>`;
      })
      .join("");
    return `<tr><td>${esc(shortHash(entry.apiKeyHash))}</td>${cells}</tr>`;
  }).join("");
  const head = ["API key", ...fields].map((f) => `<th>${esc(f)}</th>`).join("");
  return section(
    `${title} <span class="count">${entries.length}</span>`,
    `<table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderWidgetTokensSection(entries: storage.ScopedEntry<string>[]): string {
  if (entries.length === 0) return section("Widget push tokens", `<p class="empty">None registered.</p>`);
  const rows = entries.map((entry) => {
    const parts = entry.key.split(":"); // widget-token:hash:deviceId:kind
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(parts[2] ?? "")}</code></td>
      <td><code>${esc(parts[3] ?? "")}</code></td>
      <td><code class="tok">${esc(truncate(entry.value, 24))}</code></td>
    </tr>`;
  }).join("");
  return section(
    `Widget push tokens <span class="count">${entries.length}</span>`,
    `<table><thead><tr><th>API key</th><th>device id</th><th>widget kind</th><th>token</th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderActivitiesSection(entries: storage.ScopedEntry<unknown>[]): string {
  if (entries.length === 0) return section("Live Activities", `<p class="empty">None registered.</p>`);
  const rows = entries.map((entry) => {
    const v = entry.value as Record<string, unknown>;
    const externalId = entry.key.split(":").slice(2).join(":");
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(externalId)}</code></td>
      <td>${esc(String(v.kind ?? ""))}</td>
      <td><code>${esc(String(v.deviceId ?? ""))}</code></td>
      <td><code class="tok">${esc(truncate(String(v.pushToken ?? ""), 24))}</code></td>
      <td class="ts">${esc(String(v.updatedAt ?? ""))}</td>
    </tr>`;
  }).join("");
  return section(
    `Live Activities <span class="count">${entries.length}</span>`,
    `<table><thead><tr><th>API key</th><th>externalActivityId</th><th>kind</th><th>device</th><th>push token</th><th>updatedAt</th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderPendingSection(entries: storage.ScopedEntry<unknown>[]): string {
  if (entries.length === 0) return section("Pending Live Activities", `<p class="empty">None queued.</p>`);
  const rows = entries.map((entry) => {
    const v = entry.value as Record<string, unknown>;
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(String(v.externalActivityId ?? ""))}</code></td>
      <td>${esc(String(v.kind ?? ""))}</td>
      <td>${esc(String(v.title ?? ""))}</td>
      <td>${esc(String(v.state ?? ""))}</td>
    </tr>`;
  }).join("");
  return section(
    `Pending Live Activities <span class="count">${entries.length}</span>`,
    `<table><thead><tr><th>API key</th><th>externalActivityId</th><th>kind</th><th>title</th><th>state</th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderStartTokensSection(entries: storage.ScopedEntry<string>[]): string {
  if (entries.length === 0) return section("Push-to-start tokens", `<p class="empty">None registered.</p>`);
  const rows = entries.map((entry) => {
    const parts = entry.key.split(":"); // start-token:hash:deviceId:attributesType
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(parts[2] ?? "")}</code></td>
      <td><code>${esc(parts[3] ?? "")}</code></td>
      <td><code class="tok">${esc(truncate(entry.value, 24))}</code></td>
    </tr>`;
  }).join("");
  return section(
    `Push-to-start tokens <span class="count">${entries.length}</span>`,
    `<table><thead><tr><th>API key</th><th>device id</th><th>attributes type</th><th>token</th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function section(title: string, body: string): string {
  return `<section><h2>${title}</h2>${body}</section>`;
}

function renderError(message: string): string {
  return baseHTML(
    "00Widget · Admin error",
    `<header><h1>00Widget · Admin</h1></header>
     <section><h2>Error</h2><p class="error">${esc(message)}</p>
     <p><a href="/admin/login">try again</a></p></section>`,
  );
}

function renderConfigError(env: Env): string {
  const missing: string[] = [];
  if (!env.APPLE_SIGN_IN_CLIENT_ID) missing.push("APPLE_SIGN_IN_CLIENT_ID");
  if (!env.APPLE_SIGN_IN_REDIRECT_URI) missing.push("APPLE_SIGN_IN_REDIRECT_URI");
  if (!env.ADMIN_EMAILS) missing.push("ADMIN_EMAILS");
  if (!env.SESSION_SECRET) missing.push("SESSION_SECRET");
  return baseHTML(
    "00Widget · Admin not configured",
    `<header><h1>00Widget · Admin</h1></header>
     <section><h2>Admin not configured</h2>
     <p>Set the following Wrangler secrets and redeploy:</p>
     <ul>${missing.map((k) => `<li><code>${esc(k)}</code></li>`).join("")}</ul>
     <p>Setup walkthrough: <code>server/README.md</code> → "Admin dashboard (Sign in with Apple)".</p></section>`,
  );
}

function baseHTML(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f8fbff;
    --fg: #06152a;
    --muted: #56657a;
    --line: #e2e7ee;
    --accent: #0968e8;
    --good: #11a789;
    --warn: #b86a00;
    --crit: #c62828;
    --offline: #98a2b3;
    --code-bg: #eef2f7;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #06152a;
      --fg: #f8fbff;
      --muted: #98a8c0;
      --line: #1a2b48;
      --accent: #22a8ff;
      --good: #24d6b5;
      --code-bg: #0c2340;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px; max-width: 1200px; margin: 0 auto;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    background: var(--bg); color: var(--fg);
  }
  header { display: flex; align-items: baseline; justify-content: space-between; flex-wrap: wrap; gap: 12px; padding-bottom: 16px; border-bottom: 1px solid var(--line); margin-bottom: 24px; }
  header h1 { margin: 0; font-size: 22px; font-weight: 800; }
  .meta { color: var(--muted); font-size: 13px; }
  .meta a { color: var(--accent); }
  section { margin: 32px 0; }
  section h2 { font-size: 16px; font-weight: 700; margin: 0 0 12px; display: flex; align-items: baseline; gap: 8px; }
  .count { color: var(--muted); font-weight: 500; font-size: 13px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
  th { font-weight: 600; color: var(--muted); font-size: 11px; letter-spacing: .04em; text-transform: uppercase; }
  td.ts { color: var(--muted); white-space: nowrap; }
  code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  code { background: var(--code-bg); padding: 1px 6px; border-radius: 4px; font-size: 12px; }
  pre { background: var(--code-bg); padding: 10px 12px; border-radius: 6px; overflow-x: auto; font-size: 11.5px; margin: 8px 0 0; }
  details summary { cursor: pointer; color: var(--accent); font-size: 12px; }
  .empty { color: var(--muted); font-size: 13px; }
  .error { color: var(--crit); }
  .tok { font-size: 11px; color: var(--muted); }
  .status { font-size: 11px; padding: 2px 8px; border-radius: 999px; background: var(--code-bg); color: var(--muted); }
  .status-good, .status-finished { color: var(--good); }
  .status-warning, .status-paused { color: var(--warn); }
  .status-critical { color: var(--crit); }
  .status-running { color: var(--accent); }
  .status-offline, .status-unknown { color: var(--offline); }
</style>
</head>
<body>
${body}
</body>
</html>`;
}

// ---------- Helpers ----------

function htmlResponse(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function shortHash(hash: string): string {
  return hash ? hash.slice(0, 8) : "(none)";
}

function truncate(s: string, max = 60): string {
  if (s.length <= max) return s;
  return s.slice(0, max - 1) + "…";
}

function parseCookies(header: string | null): Record<string, string> {
  if (!header) return {};
  return Object.fromEntries(
    header.split(";").map((s) => {
      const [k, ...v] = s.trim().split("=");
      return [k, v.join("=")];
    }),
  );
}

function oauthCookie(name: string, value: string): string {
  return `${name}=${value}; Path=/admin; Max-Age=600; HttpOnly; Secure; SameSite=None`;
}

function expireOauthCookie(name: string): string {
  return `${name}=; Path=/admin; Max-Age=0; HttpOnly; Secure; SameSite=None`;
}
