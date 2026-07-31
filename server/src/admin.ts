import type { Env } from "./types";
import {
  apiTokenLoginEnabled,
  appleSignInConfigured,
  buildAuthorizeURL,
  clearSessionCookie,
  hashAdminApiToken,
  isAdminEmail,
  makeSessionCookie,
  randomToken,
  readSessionCookie,
  validateAppleIdToken,
  type AdminAuthMethod,
  type AdminSession,
} from "./appleAuth";
import {
  createApiKey,
  isValidApiKey,
  listApiKeys,
  listTenants,
  revokeApiKey,
  type ApiKeyRecord,
  type TenantRecord,
} from "./auth";
import * as storage from "./storage";
import { deleteCardForTenant } from "./cards";
import { endAndDeleteActivity } from "./liveActivities";
import {
  incrementRateLimitBuckets,
  listTenantRateLimitBuckets,
  rateLimitResponse,
  type RateLimitBucketView,
} from "./rateLimit";

const STATE_COOKIE = "zw_admin_state";
const NONCE_COOKIE = "zw_admin_nonce";
const API_TOKEN_LABEL = "api-token";
const ADMIN_HTML_SECURITY_HEADERS = {
  "content-security-policy": [
    "default-src 'none'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    "style-src 'unsafe-inline'",
  ].join("; "),
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
} as const;

// ---------- Routes ----------

export async function handleAdminLogin(_req: Request, env: Env): Promise<Response> {
  const apple = appleSignInConfigured(env);
  const apiToken = apiTokenLoginEnabled(env) && Boolean(env.API_KEYS);
  if (!apple && !apiToken) return htmlResponse(renderConfigError(env), 500);
  return htmlResponse(renderLoginPage(env, { apple, apiToken }));
}

export async function handleAdminLoginApple(_req: Request, env: Env): Promise<Response> {
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

export async function handleAdminLoginApiToken(req: Request, env: Env): Promise<Response> {
  if (!apiTokenLoginEnabled(env)) {
    return htmlResponse(renderError("API-token login is disabled (set ADMIN_API_TOKEN_LOGIN=true to enable)."), 403);
  }
  if (!env.SESSION_SECRET) {
    return htmlResponse(renderError("SESSION_SECRET is not set."), 500);
  }
  const limited = await enforceAdminApiTokenLoginRateLimit(req, env);
  if (limited) return limited;
  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return htmlResponse(renderError("missing form body"), 400);
  }
  const apiKey = String(form.get("apiKey") ?? "");
  if (!apiKey) return htmlResponse(renderError("API token is required"), 400);
  if (!isValidApiKey(env, apiKey)) {
    return htmlResponse(renderError("Invalid API token."), 401);
  }
  const cookie = await makeSessionCookie(env, API_TOKEN_LABEL, "api-token", {
    apiTokenHash: await hashAdminApiToken(apiKey),
  });
  const headers = new Headers({ Location: "/admin" });
  headers.append("Set-Cookie", cookie);
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

export async function handleAdminCreateApiKey(req: Request, env: Env): Promise<Response> {
  const session = await requireAdminMutationSession(req, env);
  if (session instanceof Response) return session;

  let input: { tenantId?: string; ownerEmail?: string; label?: string };
  try {
    input = await parseCreateApiKeyInput(req);
  } catch (err) {
    return htmlResponse(renderError((err as Error).message), 400);
  }
  if (!wantsJson(req) && !input.tenantId && !input.ownerEmail) {
    return htmlResponse(renderError("Select a tenant before creating an API token."), 400);
  }

  let created: Awaited<ReturnType<typeof createApiKey>>;
  try {
    created = await createApiKey(env, input);
  } catch (err) {
    const message = err instanceof Error ? err.message : "failed to create API key";
    return wantsJson(req)
      ? new Response(JSON.stringify({ error: message }), {
          status: 400,
          headers: { "content-type": "application/json; charset=utf-8" },
        })
      : htmlResponse(renderError(message), 400);
  }
  if (wantsJson(req)) {
    return new Response(JSON.stringify(created), {
      status: 201,
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  }
  return htmlResponse(
    baseHTML(
      "00Widget · API token created",
      `<header><h1>API token created</h1><div class="meta"><a href="/admin">back to admin</a></div></header>
       <section>
         <h2>Copy this token now</h2>
         <p class="muted">It is stored only as a SHA-256 hash and cannot be recovered later.</p>
         <pre>${esc(created.token)}</pre>
         <table><tbody>
           <tr><th>Owner email</th><td>${esc(created.tenant.ownerEmail)}</td></tr>
           <tr><th>Tenant id</th><td><code>${esc(created.tenant.id)}</code></td></tr>
           <tr><th>Label</th><td>${esc(created.apiKey.label)}</td></tr>
           <tr><th>API key id</th><td><code>${esc(created.apiKey.id)}</code></td></tr>
         </tbody></table>
         <p><a href="/admin?tenant=${enc(created.tenant.id)}">back to tenant</a></p>
       </section>`,
    ),
    201,
  );
}

export async function handleAdminRevokeApiKey(
  req: Request,
  env: Env,
  apiKeyId: string,
): Promise<Response> {
  const session = await requireAdminMutationSession(req, env);
  if (session instanceof Response) return session;
  const revoked = await revokeApiKey(env, apiKeyId);
  if (wantsJson(req)) {
    return new Response(JSON.stringify({ ok: revoked }), {
      status: revoked ? 200 : 404,
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  }
  return new Response(null, { status: 302, headers: { Location: "/admin" } });
}

export async function handleAdminDeleteCard(
  req: Request,
  env: Env,
  tenantIdRaw: string,
  cardIdRaw: string,
  ctx: ExecutionContext,
): Promise<Response> {
  const session = await requireAdminMutationSession(req, env);
  if (session instanceof Response) return session;
  const tenantId = dec(tenantIdRaw);
  await deleteCardForTenant(env, tenantId, dec(cardIdRaw), ctx);
  return redirectToTenant(tenantId);
}

export async function handleAdminDeleteWidgetToken(
  req: Request,
  env: Env,
  tenantIdRaw: string,
  deviceIdRaw: string,
  widgetKindRaw: string,
): Promise<Response> {
  const session = await requireAdminMutationSession(req, env);
  if (session instanceof Response) return session;
  const tenantId = dec(tenantIdRaw);
  await storage.deleteWidgetToken(env, tenantId, dec(deviceIdRaw), dec(widgetKindRaw));
  return redirectToTenant(tenantId);
}

export async function handleAdminDeleteLiveActivity(
  req: Request,
  env: Env,
  tenantIdRaw: string,
  externalActivityIdRaw: string,
): Promise<Response> {
  const session = await requireAdminMutationSession(req, env);
  if (session instanceof Response) return session;
  const tenantId = dec(tenantIdRaw);
  await endAndDeleteActivity(env, tenantId, dec(externalActivityIdRaw), {}, {
    deleteOnDeliveryFailure: true,
  });
  return redirectToTenant(tenantId);
}

export async function handleAdminDeletePendingLiveActivity(
  req: Request,
  env: Env,
  tenantIdRaw: string,
  externalActivityIdRaw: string,
): Promise<Response> {
  const session = await requireAdminMutationSession(req, env);
  if (session instanceof Response) return session;
  const tenantId = dec(tenantIdRaw);
  await storage.deletePendingActivity(env, tenantId, dec(externalActivityIdRaw));
  return redirectToTenant(tenantId);
}

export async function handleAdminDeleteStartToken(
  req: Request,
  env: Env,
  tenantIdRaw: string,
  deviceIdRaw: string,
  attributesTypeRaw: string,
): Promise<Response> {
  const session = await requireAdminMutationSession(req, env);
  if (session instanceof Response) return session;
  const tenantId = dec(tenantIdRaw);
  await storage.deleteStartToken(env, tenantId, dec(deviceIdRaw), dec(attributesTypeRaw));
  return redirectToTenant(tenantId);
}

export async function handleAdminDashboard(req: Request, env: Env): Promise<Response> {
  const apple = appleSignInConfigured(env);
  const apiToken = apiTokenLoginEnabled(env) && Boolean(env.API_KEYS) && Boolean(env.SESSION_SECRET);
  if (!apple && !apiToken) return htmlResponse(renderConfigError(env), 500);
  const session = await requireAdminSession(req, env);
  if (!session) {
    return new Response(null, { status: 302, headers: { Location: "/admin/login" } });
  }

  const selectedTenantId = new URL(req.url).searchParams.get("tenant")?.trim() || undefined;
  const [tenants, apiKeys] = await Promise.all([listTenants(env), listApiKeys(env)]);
  const selectedTenant = selectedTenantId
    ? tenants.find((tenant) => tenant.id === selectedTenantId)
    : undefined;
  const tenantRows = selectedTenant
    ? await loadTenantRows(env, selectedTenant.id)
    : emptyTenantRows();

  return htmlResponse(
    renderDashboard({
      session,
      tenants,
      apiKeys,
      selectedTenant,
      rows: tenantRows,
    }),
  );
}

// ---------- HTML rendering ----------

interface DashboardData {
  session: AdminSession;
  tenants: TenantRecord[];
  apiKeys: ApiKeyRecord[];
  selectedTenant?: TenantRecord;
  rows: TenantRows;
}

function renderDashboard(d: DashboardData): string {
  const method: AdminAuthMethod = d.session.method;
  const signedInAs = method === "api-token"
    ? `Signed in <strong>via API token</strong>`
    : `Signed in as <strong>${esc(d.session.email)}</strong>`;
  return baseHTML(
    "00Widget · Admin",
    `
    <header>
      <h1>00Widget · Admin</h1>
      <div class="meta">
        ${signedInAs}
        · <a href="/admin/logout">log out</a>
      </div>
    </header>

    ${renderApiKeyAdminSection(d.tenants, d.apiKeys, d.session.csrf)}
    ${renderTenantDetail(d)}
    `,
  );
}

interface TenantRows {
  cards: storage.ScopedEntry<unknown>[];
  devices: storage.ScopedEntry<unknown>[];
  widgetTokens: storage.ScopedEntry<storage.WidgetTokenRecord>[];
  activities: storage.ScopedEntry<unknown>[];
  pending: storage.ScopedEntry<unknown>[];
  startTokens: storage.ScopedEntry<string>[];
  rateLimits: RateLimitBucketView[];
}

async function loadTenantRows(env: Env, tenantId: string): Promise<TenantRows> {
  const [cards, devices, widgetTokens, activities, pending, startTokens, rateLimits] = await Promise.all([
    storage.listTenantCards(env, tenantId),
    storage.listTenantDevices(env, tenantId),
    storage.listTenantWidgetTokens(env, tenantId),
    storage.listTenantActivities(env, tenantId),
    storage.listTenantPendingActivities(env, tenantId),
    storage.listTenantStartTokens(env, tenantId),
    listTenantRateLimitBuckets(env, tenantId),
  ]);
  return { cards, devices, widgetTokens, activities, pending, startTokens, rateLimits };
}

function emptyTenantRows(): TenantRows {
  return {
    cards: [],
    devices: [],
    widgetTokens: [],
    activities: [],
    pending: [],
    startTokens: [],
    rateLimits: [],
  };
}

function renderApiKeyAdminSection(tenants: TenantRecord[], apiKeys: ApiKeyRecord[], csrf: string): string {
  const rows = tenants.map((tenant) => {
    const tenantApiKeys = apiKeys.filter((key) => key.tenantId === tenant.id);
    const active = tenantApiKeys.filter((key) => !key.revokedAt).length;
    return `<tr>
      <td><a href="/admin?tenant=${enc(tenant.id)}">${esc(tenant.ownerEmail || "(no owner email)")}</a></td>
      <td><code>${esc(shortHash(tenant.id))}</code></td>
      <td>${esc(String(active))}</td>
      <td>${esc(String(tenantApiKeys.length - active))}</td>
      <td class="ts">${esc(tenant.createdAt)}</td>
      <td><a class="button button-small" href="/admin?tenant=${enc(tenant.id)}">View</a></td>
    </tr>`;
  }).join("");

  return section(
    `Tenants & API keys <span class="count">${tenants.length} tenants · ${apiKeys.length} keys</span>`,
    `<form method="post" action="/admin/api-keys" class="api-key-form">
       ${csrfInput(csrf)}
       <label>Owner email
         <input type="email" name="ownerEmail" placeholder="owner@example.com" required>
       </label>
       <input type="hidden" name="label" value="default">
       <button class="button" type="submit">Create tenant</button>
     </form>
     ${tenants.length === 0
        ? `<p class="empty">No tenants created yet.</p>`
        : `<table><thead><tr><th>tenant</th><th>id</th><th>active keys</th><th>revoked keys</th><th>created</th><th></th></tr></thead><tbody>${rows}</tbody></table>`}`,
  );
}

function renderTenantDetail(d: DashboardData): string {
  if (!d.selectedTenant) {
    if (d.tenants.length === 0) return "";
    return section("Tenant detail", `<p class="empty">Select a tenant to view cards, devices, tokens, and Live Activities.</p>`);
  }

  const tenantApiKeys = d.apiKeys.filter((key) => key.tenantId === d.selectedTenant!.id);
  return `
    <section>
      <h2>Tenant <span class="count">${esc(d.selectedTenant.ownerEmail || d.selectedTenant.id)}</span></h2>
      <table><tbody>
        <tr><th>tenant id</th><td><code>${esc(d.selectedTenant.id)}</code></td></tr>
        <tr><th>owner email</th><td>${esc(d.selectedTenant.ownerEmail)}</td></tr>
        <tr><th>created</th><td class="ts">${esc(d.selectedTenant.createdAt)}</td></tr>
      </tbody></table>
    </section>
    ${renderTenantApiKeysSection(d.selectedTenant, tenantApiKeys, d.session.csrf)}
    ${renderCardsSection(d.selectedTenant.id, d.rows.cards, d.session.csrf)}
    ${renderTokenSection("Devices", d.rows.devices, ["device id", "apnsDeviceToken", "appVersion", "platform", "updatedAt"])}
    ${renderWidgetTokensSection(d.selectedTenant.id, d.rows.widgetTokens, d.session.csrf)}
    ${renderActivitiesSection(d.selectedTenant.id, d.rows.activities, d.session.csrf)}
    ${renderPendingSection(d.selectedTenant.id, d.rows.pending, d.session.csrf)}
    ${renderStartTokensSection(d.selectedTenant.id, d.rows.startTokens, d.session.csrf)}
    ${renderRateLimitsSection(d.rows.rateLimits)}
  `;
}

function renderTenantApiKeysSection(tenant: TenantRecord, apiKeys: ApiKeyRecord[], csrf: string): string {
  const rows = apiKeys.map((key) => {
    const active = key.revokedAt ? "revoked" : "active";
    const action = key.revokedAt
      ? ""
      : `<form method="post" action="/admin/api-keys/${esc(key.id)}/revoke">
           ${csrfInput(csrf)}
           <button class="button button-small" type="submit">Revoke</button>
         </form>`;
    return `<tr>
      <td><code>${esc(shortHash(key.id))}</code></td>
      <td>${esc(key.label)}</td>
      <td><code>${esc(shortHash(key.tokenHash))}</code></td>
      <td>${esc(active)}</td>
      <td class="ts">${esc(key.createdAt)}</td>
      <td class="ts">${esc(key.lastUsedAt ?? "")}</td>
      <td>${action}</td>
    </tr>`;
  }).join("");
  return section(
    `API keys <span class="count">${apiKeys.length}</span>`,
    `<form method="post" action="/admin/api-keys" class="api-key-form api-key-form-tenant">
       ${csrfInput(csrf)}
       <input type="hidden" name="tenantId" value="${esc(tenant.id)}">
       <label>Token label
         <input type="text" name="label" placeholder="Production iPhone">
       </label>
       <button class="button" type="submit">Create API token</button>
     </form>
     ${apiKeys.length === 0
      ? `<p class="empty">No API keys for this tenant.</p>`
      : `<table><thead><tr><th>id</th><th>label</th><th>token hash</th><th>state</th><th>created</th><th>last used</th><th></th></tr></thead><tbody>${rows}</tbody></table>`}`,
  );
}

function renderLoginPage(_env: Env, opts: { apple: boolean; apiToken: boolean }): string {
  const appleBlock = opts.apple
    ? `<a class="button button-apple" href="/admin/login/apple">Sign in with Apple</a>`
    : `<p class="muted">Sign in with Apple is not configured.</p>`;

  const apiTokenBlock = opts.apiToken
    ? `<form method="post" action="/admin/login/api-token" class="api-token-form">
         <label for="apiKey">API token</label>
         <input id="apiKey" type="password" name="apiKey" autocomplete="off" autofocus required>
         <button type="submit" class="button">Sign in with API token</button>
         <p class="muted">Fallback while Sign in with Apple isn't configured. Opt in by setting <code>ADMIN_API_TOKEN_LOGIN=true</code>.</p>
       </form>`
    : "";

  const separator = opts.apple && opts.apiToken
    ? `<div class="divider"><span>or</span></div>`
    : "";

  return baseHTML(
    "00Widget · Admin · Sign in",
    `<header><h1>00Widget · Admin</h1></header>
     <section class="login">
       <h2>Sign in</h2>
       ${appleBlock}
       ${separator}
       ${apiTokenBlock}
     </section>`,
  );
}

function renderCardsSection(tenantId: string, cards: storage.ScopedEntry<unknown>[], csrf: string): string {
  if (cards.length === 0) return section("Cards", "<p class=\"empty\">No cards published yet.</p>");
  const rows = cards.map((entry) => {
    const c = entry.value as Record<string, unknown>;
    const cardId = String(c.id ?? "");
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(cardId)}</code></td>
      <td>${esc(String(c.template ?? ""))}</td>
      <td>${esc(String(c.title ?? ""))}</td>
      <td><span class="status status-${esc(String(c.status ?? "unknown"))}">${esc(String(c.status ?? "unknown"))}</span></td>
      <td class="ts">${esc(String(c.updatedAt ?? ""))}</td>
      <td><details><summary>json</summary><pre>${esc(JSON.stringify(c, null, 2))}</pre></details></td>
      <td>${deleteForm(`/admin/tenants/${enc(tenantId)}/cards/${enc(cardId)}/delete`, "Delete", csrf)}</td>
    </tr>`;
  }).join("");
  return section(
    `Cards <span class="count">${cards.length}</span>`,
    `<table><thead><tr><th>API key</th><th>id</th><th>template</th><th>title</th><th>status</th><th>updatedAt</th><th>raw</th><th></th></tr></thead><tbody>${rows}</tbody></table>`,
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

function renderWidgetTokensSection(
  tenantId: string,
  entries: storage.ScopedEntry<storage.WidgetTokenRecord>[],
  csrf: string,
): string {
  if (entries.length === 0) return section("Widget push tokens", `<p class="empty">None registered.</p>`);
  const rows = entries.map((entry) => {
    const parts = entry.key.split(":"); // widget-token:hash:deviceId:kind
    const deviceId = parts[2] ?? "";
    const widgetKind = parts[3] ?? "";
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(deviceId)}</code></td>
      <td><code>${esc(widgetKind)}</code></td>
      <td><code class="tok">${esc(truncate(entry.value.token, 24))}</code></td>
      <td>${esc(entry.value.appVersion)}</td>
      <td>${esc(entry.value.platform)}</td>
      <td class="ts">${esc(entry.value.updatedAt)}</td>
      <td>${deleteForm(`/admin/tenants/${enc(tenantId)}/widget-tokens/${enc(deviceId)}/${enc(widgetKind)}/delete`, "Delete", csrf)}</td>
    </tr>`;
  }).join("");
  return section(
    `Widget push tokens <span class="count">${entries.length}</span>`,
    `<table><thead><tr><th>API key</th><th>device id</th><th>widget kind</th><th>token</th><th>app build</th><th>platform</th><th>registered</th><th></th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderActivitiesSection(tenantId: string, entries: storage.ScopedEntry<unknown>[], csrf: string): string {
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
      <td>${deleteForm(`/admin/tenants/${enc(tenantId)}/live-activities/${enc(externalId)}/delete`, "Delete", csrf)}</td>
    </tr>`;
  }).join("");
  return section(
    `Live Activities <span class="count">${entries.length}</span>`,
    `<table><thead><tr><th>API key</th><th>externalActivityId</th><th>kind</th><th>device</th><th>push token</th><th>updatedAt</th><th></th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderPendingSection(tenantId: string, entries: storage.ScopedEntry<unknown>[], csrf: string): string {
  if (entries.length === 0) return section("Pending Live Activities", `<p class="empty">None queued.</p>`);
  const rows = entries.map((entry) => {
    const v = entry.value as Record<string, unknown>;
    const externalId = String(v.externalActivityId ?? "");
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(externalId)}</code></td>
      <td>${esc(String(v.kind ?? ""))}</td>
      <td>${esc(String(v.title ?? ""))}</td>
      <td>${esc(String(v.state ?? ""))}</td>
      <td>${deleteForm(`/admin/tenants/${enc(tenantId)}/pending-live-activities/${enc(externalId)}/delete`, "Delete", csrf)}</td>
    </tr>`;
  }).join("");
  return section(
    `Pending Live Activities <span class="count">${entries.length}</span>`,
    `<table><thead><tr><th>API key</th><th>externalActivityId</th><th>kind</th><th>title</th><th>state</th><th></th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderStartTokensSection(tenantId: string, entries: storage.ScopedEntry<string>[], csrf: string): string {
  if (entries.length === 0) return section("Push-to-start tokens", `<p class="empty">None registered.</p>`);
  const rows = entries.map((entry) => {
    const parts = entry.key.split(":"); // start-token:hash:deviceId:attributesType
    const deviceId = parts[2] ?? "";
    const attributesType = parts[3] ?? "";
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(deviceId)}</code></td>
      <td><code>${esc(attributesType)}</code></td>
      <td><code class="tok">${esc(truncate(entry.value, 24))}</code></td>
      <td>${deleteForm(`/admin/tenants/${enc(tenantId)}/start-tokens/${enc(deviceId)}/${enc(attributesType)}/delete`, "Delete", csrf)}</td>
    </tr>`;
  }).join("");
  return section(
    `Push-to-start tokens <span class="count">${entries.length}</span>`,
    `<table><thead><tr><th>API key</th><th>device id</th><th>attributes type</th><th>token</th><th></th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderRateLimitsSection(entries: RateLimitBucketView[]): string {
  if (entries.length === 0) {
    return section("Rate limits", `<p class="empty">No active rate limit buckets for this tenant.</p>`);
  }
  const important = entries.filter((entry) =>
    [
      "All writes",
      "Card upserts",
      "Card upserts per card",
      "Live Activity updates",
      "Live Activity updates per activity",
      "Action runs",
      "Action runs per action",
      "Registrations",
      "Webhook changes",
      "Share mutations",
    ].includes(entry.label),
  );
  const rows = important.map((entry) => {
    return `<tr>
      <td>${esc(entry.label)}</td>
      <td><code>${esc(shortBucketKey(entry.bucketKey))}</code></td>
      <td>${esc(String(entry.count))} / ${esc(String(entry.limit))}</td>
      <td>${esc(String(entry.remaining))}</td>
      <td>${esc(formatWindow(entry.windowSeconds))}</td>
      <td class="ts">${esc(new Date(entry.resetAt * 1000).toISOString())}</td>
    </tr>`;
  }).join("");
  return section(
    `Rate limits <span class="count">${important.length} active buckets</span>`,
    `<table><thead><tr><th>bucket</th><th>key</th><th>used</th><th>remaining</th><th>window</th><th>resets</th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function section(title: string, body: string): string {
  return `<section><h2>${title}</h2>${body}</section>`;
}

function csrfInput(csrf: string): string {
  return `<input type="hidden" name="csrf" value="${esc(csrf)}">`;
}

function deleteForm(action: string, label: string, csrf: string): string {
  return `<form method="post" action="${esc(action)}">
    ${csrfInput(csrf)}
    <button class="button button-small button-danger" type="submit">${esc(label)}</button>
  </form>`;
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
  const apple: string[] = [];
  if (!env.APPLE_SIGN_IN_CLIENT_ID) apple.push("APPLE_SIGN_IN_CLIENT_ID");
  if (!env.APPLE_SIGN_IN_REDIRECT_URI) apple.push("APPLE_SIGN_IN_REDIRECT_URI");
  if (!env.ADMIN_EMAILS) apple.push("ADMIN_EMAILS");
  if (!env.SESSION_SECRET) apple.push("SESSION_SECRET");

  const apiToken: string[] = [];
  if (!env.API_KEYS) apiToken.push("API_KEYS");
  if (!env.SESSION_SECRET) apiToken.push("SESSION_SECRET");
  const apiTokenDisabled = !apiTokenLoginEnabled(env);

  return baseHTML(
    "00Widget · Admin not configured",
    `<header><h1>00Widget · Admin</h1></header>
     <section><h2>Admin not configured</h2>
     <p>Enable at least one sign-in method by setting its required Wrangler secrets and redeploying.</p>
     <h3>Sign in with Apple</h3>
     <ul>${apple.map((k) => `<li><code>${esc(k)}</code></li>`).join("") || "<li><em>all set</em></li>"}</ul>
     <h3>API-token fallback</h3>
     ${apiTokenDisabled
        ? `<p class="muted">Disabled by default. Set <code>ADMIN_API_TOKEN_LOGIN=true</code> to enable temporarily.</p>`
        : `<ul>${apiToken.map((k) => `<li><code>${esc(k)}</code></li>`).join("") || "<li><em>all set</em></li>"}</ul>`}
     <p>Setup walkthrough: <code>server/README.md</code> → "Admin dashboard".</p></section>`,
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
  .login { max-width: 420px; margin: 24px auto; }
  .login h2 { margin-bottom: 16px; }
  .login label { display: block; font-size: 12px; font-weight: 600; color: var(--muted); margin-bottom: 6px; text-transform: uppercase; letter-spacing: .04em; }
  .login input[type=password] { width: 100%; padding: 10px 12px; border-radius: 6px; border: 1px solid var(--line); background: var(--bg); color: var(--fg); font: inherit; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  .button { display: inline-block; padding: 10px 18px; margin-top: 12px; border-radius: 6px; background: var(--accent); color: white; border: 0; font: inherit; font-weight: 600; cursor: pointer; text-decoration: none; }
  .button-small { padding: 5px 9px; margin: 0; font-size: 12px; }
  .button-danger { background: var(--crit); }
  .button-apple { background: var(--fg); color: var(--bg); display: block; text-align: center; }
  .api-token-form { display: flex; flex-direction: column; gap: 4px; }
  .api-token-form .button { align-self: stretch; text-align: center; }
  .api-key-form { display: grid; grid-template-columns: minmax(180px, 1fr) minmax(180px, 1fr) minmax(180px, 1fr) auto; gap: 12px; align-items: end; margin-bottom: 16px; }
  .api-key-form label { display: flex; flex-direction: column; gap: 6px; color: var(--muted); font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em; }
  .api-key-form input, .api-key-form select { padding: 9px 10px; border-radius: 6px; border: 1px solid var(--line); background: var(--bg); color: var(--fg); font: inherit; text-transform: none; letter-spacing: normal; }
  @media (max-width: 780px) { .api-key-form { grid-template-columns: 1fr; } }
  .divider { display: flex; align-items: center; gap: 12px; margin: 20px 0; color: var(--muted); font-size: 12px; }
  .divider::before, .divider::after { content: ""; flex: 1; height: 1px; background: var(--line); }
  .muted { color: var(--muted); font-size: 12px; }
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
    headers: {
      "content-type": "text/html; charset=utf-8",
      ...ADMIN_HTML_SECURITY_HEADERS,
    },
  });
}

async function requireAdminSession(req: Request, env: Env): Promise<AdminSession | null> {
  return readSessionCookie(env, req);
}

async function requireAdminMutationSession(req: Request, env: Env): Promise<AdminSession | Response> {
  const session = await requireAdminSession(req, env);
  if (!session) return new Response(null, { status: 302, headers: { Location: "/admin/login" } });
  if (!sameOriginAdminRequest(req)) {
    return htmlResponse(renderError("Invalid admin request origin."), 403);
  }
  const token = await csrfTokenFromRequest(req);
  if (!token || !constantTimeEqual(token, session.csrf)) {
    return htmlResponse(renderError("Invalid admin CSRF token."), 403);
  }
  return session;
}

async function enforceAdminApiTokenLoginRateLimit(req: Request, env: Env): Promise<Response | null> {
  const exceeded = await incrementRateLimitBuckets(env, [
    { policy: "adminApiTokenLoginIpHour", key: adminLoginIpKey(req) },
  ]);
  if (!exceeded) return null;
  if (wantsJson(req)) return rateLimitResponse(exceeded);
  return htmlResponse(
    renderError(`Too many API-token login attempts. Try again after ${formatWindow(exceeded.retryAfter)}.`),
    429,
  );
}

function adminLoginIpKey(req: Request): string {
  const cfIp = req.headers.get("cf-connecting-ip")?.trim();
  const forwardedIp = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return `admin-login:${cfIp || forwardedIp || "unknown"}`;
}

function sameOriginAdminRequest(req: Request): boolean {
  const expected = new URL(req.url).origin;
  const origin = req.headers.get("origin");
  if (origin) return origin === expected;
  const referer = req.headers.get("referer");
  if (!referer) return true;
  try {
    return new URL(referer).origin === expected;
  } catch {
    return false;
  }
}

async function csrfTokenFromRequest(req: Request): Promise<string | null> {
  const header = req.headers.get("x-csrf-token")?.trim();
  if (header) return header;
  const contentType = req.headers.get("content-type") ?? "";
  try {
    if (contentType.includes("application/json")) {
      const data = (await req.clone().json()) as Record<string, unknown>;
      return stringField(data.csrf) ?? null;
    }
    const form = await req.clone().formData();
    return stringField(form.get("csrf")) ?? null;
  } catch {
    return null;
  }
}

async function parseCreateApiKeyInput(
  req: Request,
): Promise<{ tenantId?: string; ownerEmail?: string; label?: string }> {
  const contentType = req.headers.get("content-type") ?? "";
  if (contentType.includes("application/json")) {
    const data = (await req.json()) as Record<string, unknown>;
    return {
      tenantId: stringField(data.tenantId),
      ownerEmail: stringField(data.ownerEmail),
      label: stringField(data.label),
    };
  }
  const form = await req.formData();
  return {
    tenantId: stringField(form.get("tenantId")),
    ownerEmail: stringField(form.get("ownerEmail")),
    label: stringField(form.get("label")),
  };
}

function stringField(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed || undefined;
}

function wantsJson(req: Request): boolean {
  const accept = req.headers.get("accept") ?? "";
  const contentType = req.headers.get("content-type") ?? "";
  return accept.includes("application/json") || contentType.includes("application/json");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function enc(s: string): string {
  return encodeURIComponent(s);
}

function dec(s: string): string {
  return decodeURIComponent(s);
}

function redirectToTenant(tenantId: string): Response {
  return new Response(null, { status: 302, headers: { Location: `/admin?tenant=${enc(tenantId)}` } });
}

function shortHash(hash: string): string {
  return hash ? hash.slice(0, 8) : "(none)";
}

function truncate(s: string, max = 60): string {
  if (s.length <= max) return s;
  return s.slice(0, max - 1) + "…";
}

function shortBucketKey(bucketKey: string): string {
  return bucketKey.replace(/^[^:]+:tenant:[^:]+:?/, "");
}

function formatWindow(seconds: number): string {
  if (seconds === 60 * 60) return "1h";
  if (seconds === 24 * 60 * 60) return "24h";
  return `${seconds}s`;
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
