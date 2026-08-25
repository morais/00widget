import { isValidEmail, type Env } from "./types";
import {
  ApiScopePresets,
  createApiKey,
  listApiKeys,
  listTenants,
  type ApiKeyRecord,
  type ApiScope,
  type TenantRecord,
} from "./auth";
import { baseHTML, dec, enc, esc, htmlResponse, renderError } from "./html";
import {
  adminAccessConfigured,
  adminEmails,
  apiTokenLoginConfigured,
  webSignInConfigured,
  notAnAdminResponse,
  redirectToSignIn,
  requireAdminMutationSession,
  requireWebSession,
  type WebAuthMethod,
  type WebPrincipal,
} from "./webSession";
import { revokeCredentialById } from "./sessions";
import * as storage from "./storage";
import { deleteCardForTenant } from "./cards";
import { endAndDeleteActivity } from "./liveActivities";
import { listTenantRateLimitBuckets, type RateLimitBucketView } from "./rateLimit";






export async function handleAdminCreateApiKey(req: Request, env: Env): Promise<Response> {
  const session = await requireAdminMutationSession(req, env);
  if (session instanceof Response) return session;

  let input: { tenantId?: string; ownerEmail?: string; label?: string; scopes: ApiScope[] };
  try {
    input = await parseCreateApiKeyInput(req);
  } catch (err) {
    return htmlResponse(renderError((err as Error).message), 400);
  }
  if (!wantsJson(req) && !input.tenantId && !input.ownerEmail) {
    return htmlResponse(renderError("Select a tenant before creating an API token."), 400);
  }
  // The form declares type="email" and the JSON path declares nothing, so this
  // is the first place the value is actually checked. An owner email decides
  // which Apple identity can later claim the tenant, so a malformed one is a
  // security decision made by typo — and it reaches the signup alert's headers.
  if (input.ownerEmail && !isValidEmail(input.ownerEmail)) {
    const message = "Owner email must be a valid email address.";
    return wantsJson(req)
      ? new Response(JSON.stringify({ error: message }), {
          status: 400,
          headers: { "content-type": "application/json; charset=utf-8" },
        })
      : htmlResponse(renderError(message), 400);
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
           <tr><th>Scopes</th><td><code>${esc(created.apiKey.scopes.join(", "))}</code></td></tr>
           <tr><th>API key id</th><td><code>${esc(created.apiKey.id)}</code></td></tr>
           <tr><th>Expires</th><td>${esc(created.apiKey.expiresAt)}</td></tr>
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
  const revoked = await revokeCredentialById(env, apiKeyId);
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
  const instance = await storage.getActivityInstanceByOwnerExternal(
    env,
    tenantId,
    dec(externalActivityIdRaw),
  );
  if (instance) await storage.deleteActivityInstance(env, instance.activityInstanceId);
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
  if (!adminAccessConfigured(env)) return htmlResponse(renderAdminNotConfigured(env), 500);
  const session = await requireWebSession(req, env);
  if (!session) return redirectToSignIn(req);
  // Being signed in is identity, not authority. Every route under /admin makes
  // this check; none of them infer it from the session existing.
  if (!session.isAdmin) return notAnAdminResponse(session);

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

/// Deliberately generic. The page is unauthenticated, so naming which setting
/// is unset would hand a stranger a map of what to probe; the specifics go to
/// the Worker's logs, where only the operator sees them.
function renderAdminNotConfigured(env: Env): string {
  console.warn("admin.not_configured", {
    adminEmailsConfigured: adminEmails(env).length > 0,
    webSignInConfigured: webSignInConfigured(env),
    apiTokenLoginConfigured: apiTokenLoginConfigured(env),
  });
  return baseHTML(
    "00Widget · Admin not configured",
    `<header><h1>00Widget · Admin</h1></header>
     <section><h2>Admin not configured</h2>
     <p>No administrator is configured for this deployment.</p>
     <p class="muted">If you are the operator, the missing configuration is
     named in this Worker's logs. Setup walkthrough:
     <code>server/README.md</code> → "Admin dashboard".</p></section>`,
  );
}

interface DashboardData {
  session: WebPrincipal;
  tenants: TenantRecord[];
  apiKeys: ApiKeyRecord[];
  selectedTenant?: TenantRecord;
  rows: TenantRows;
}

function renderDashboard(d: DashboardData): string {
  const method: WebAuthMethod = d.session.method;
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
        · <a href="/logout">log out</a>
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
    const active = tenantApiKeys.filter(
      (key) => !key.revokedAt && Date.parse(key.expiresAt) > Date.now(),
    ).length;
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
        : `<table><thead><tr><th>tenant</th><th>id</th><th>active keys</th><th>inactive keys</th><th>created</th><th></th></tr></thead><tbody>${rows}</tbody></table>`}`,
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
    const expired = Date.parse(key.expiresAt) <= Date.now();
    const active = key.revokedAt ? "revoked" : expired ? "expired" : "active";
    const action = key.revokedAt
      ? ""
      : `<form method="post" action="/admin/api-keys/${esc(key.id)}/revoke">
           ${csrfInput(csrf)}
           <button class="button button-small" type="submit">Revoke</button>
         </form>`;
    return `<tr>
      <td><code>${esc(shortHash(key.id))}</code></td>
      <td>${esc(key.label)}</td>
      <td><code>${esc(key.scopes.join(", "))}</code></td>
      <td><code>${esc(shortHash(key.tokenHash))}</code></td>
      <td>${esc(active)}</td>
      <td class="ts">${esc(key.createdAt)}</td>
      <td class="ts">${esc(key.lastUsedAt ?? "")}</td>
      <td class="ts">${esc(key.expiresAt)}${key.renewSeconds
        ? ` <span class="muted" title="Slides forward on use; expires only after ${formatWindow(key.renewSeconds)} idle">↻ ${esc(formatWindow(key.renewSeconds))} idle</span>`
        : ` <span class="muted" title="Fixed deadline; use does not extend it">fixed</span>`}</td>
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
       <label>Permission preset
         <select name="scopePreset">
           <option value="producer">Producer — read and publish</option>
           <option value="read-only">Read only</option>
           <option value="device">Device — read, register, and run safe actions</option>
           <option value="webhook-manager">Webhook manager</option>
         </select>
       </label>
       <button class="button" type="submit">Create API token</button>
     </form>
     ${apiKeys.length === 0
      ? `<p class="empty">No API keys for this tenant.</p>`
      : `<table><thead><tr><th>id</th><th>label</th><th>scope</th><th>token hash</th><th>state</th><th>created</th><th>last used</th><th>expires</th><th></th></tr></thead><tbody>${rows}</tbody></table>`}`,
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
    const delivery = entry.value.lastDelivery;
    return `<tr>
      <td>${esc(shortHash(entry.apiKeyHash))}</td>
      <td><code>${esc(deviceId)}</code></td>
      <td><code>${esc(widgetKind)}</code></td>
      <td><code class="tok">${esc(truncate(entry.value.token, 24))}</code></td>
      <td>${esc(entry.value.appVersion)}</td>
      <td>${esc(entry.value.platform)}</td>
      <td class="ts">${esc(entry.value.updatedAt)}</td>
      <td class="ts">${esc(delivery?.attemptedAt ?? "")}</td>
      <td>${esc(delivery ? String(delivery.status) : "")}</td>
      <td>${esc(delivery?.reason ?? "")}</td>
      <td>${esc(delivery ? String(delivery.attempts) : "")}</td>
      <td><code>${esc(delivery?.apnsId ?? "")}</code></td>
      <td>${deleteForm(`/admin/tenants/${enc(tenantId)}/widget-tokens/${enc(deviceId)}/${enc(widgetKind)}/delete`, "Delete", csrf)}</td>
    </tr>`;
  }).join("");
  return section(
    `Widget push tokens <span class="count">${entries.length}</span>`,
    `<table><thead><tr><th>API key</th><th>device id</th><th>widget kind</th><th>token</th><th>app build</th><th>platform</th><th>registered</th><th>last APNs attempt</th><th>status</th><th>reason</th><th>attempts</th><th>APNs id</th><th></th></tr></thead><tbody>${rows}</tbody></table>`,
  );
}

function renderActivitiesSection(tenantId: string, entries: storage.ScopedEntry<unknown>[], csrf: string): string {
  if (entries.length === 0) return section("Live Activities", `<p class="empty">None registered.</p>`);
  const rows = entries.map((entry) => {
    const v = entry.value as Record<string, unknown>;
    const externalId = String(v.externalActivityId ?? "");
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


// Reached by unauthenticated visitors, so the page itself stays generic — an
// itemised list of unset secrets tells an attacker exactly which sign-in
// method is half-configured and worth probing. The detail an operator needs
// goes to the Worker log instead, which only they can read.


// ---------- Helpers ----------












async function parseCreateApiKeyInput(
  req: Request,
): Promise<{ tenantId?: string; ownerEmail?: string; label?: string; scopes: ApiScope[] }> {
  const contentType = req.headers.get("content-type") ?? "";
  if (contentType.includes("application/json")) {
    const data = (await req.json()) as Record<string, unknown>;
    return {
      tenantId: stringField(data.tenantId),
      ownerEmail: stringField(data.ownerEmail),
      label: stringField(data.label),
      scopes: scopesForAdminPreset(stringField(data.scopePreset)),
    };
  }
  const form = await req.formData();
  return {
    tenantId: stringField(form.get("tenantId")),
    ownerEmail: stringField(form.get("ownerEmail")),
    label: stringField(form.get("label")),
    scopes: scopesForAdminPreset(stringField(form.get("scopePreset"))),
  };
}

function scopesForAdminPreset(preset = "producer"): ApiScope[] {
  switch (preset) {
    case "producer": return [...ApiScopePresets.producer];
    case "read-only": return [...ApiScopePresets.readOnly];
    case "device": return [...ApiScopePresets.device];
    case "webhook-manager": return [...ApiScopePresets.webhookManager];
    default: throw new Error("invalid API token permission preset");
  }
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
  // Credential renewal windows are measured in days, not rate-limit hours.
  if (seconds % (24 * 60 * 60) === 0) return `${seconds / (24 * 60 * 60)}d`;
  return `${seconds}s`;
}



// Post-sign-in destination, carried through Apple's cross-site form_post
// round trip in a cookie. Only same-origin absolute /admin paths are honoured,
// so this can never become an open redirect: no scheme, no host, no
// protocol-relative "//evil" form survives the pattern.

