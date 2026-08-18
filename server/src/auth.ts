import type { Env } from "./types";
import { adminApiTokensAreSecure, configuredAdminApiTokens } from "./adminSecurity";

export interface AuthContext {
  apiKey: string;
  apiKeyHash: string;
  apiKeyId: string;
  tenantId: string;
  credentialKind: CredentialKind;
  sessionId?: string;
  deviceId?: string;
  expiresAt: string;
  scopes: ApiScope[];
  /// Set only for `guest` credentials, which may touch exactly this resource.
  resourceKind?: string;
  resourceId?: string;
}

export type CredentialKind = "publisher" | "app" | "guest";

const API_TOKEN_PATTERN = /^(?:zw_[A-Za-z0-9_-]{43}|zwa_[A-Za-z0-9_-]{43}|zwg_[A-Za-z0-9_-]{43})$/;

export const DEFAULT_TOKEN_LIFETIME_SECONDS = 90 * 24 * 60 * 60;

// `last_used_at` (and, for a renewing credential, `expires_at`) is written at
// most this often. A 90-day window does not need minute-accurate bookkeeping.
const TOUCH_THROTTLE_MS = 60 * 60 * 1000;

export const API_SCOPES = [
  "tenant:read",
  "publish",
  "device:register",
  "actions:run",
  "actions:confirm",
  "shares:manage",
  "webhook:manage",
  "guest:read",
] as const;

export type ApiScope = typeof API_SCOPES[number];

export const ApiScopePresets = {
  // The agent that publishes a card with buttons is the same system that
  // receives the taps, so webhook administration rides on the publisher token
  // rather than a credential the app has no way to issue.
  producer: ["tenant:read", "publish", "webhook:manage"] as ApiScope[],
  readOnly: ["tenant:read"] as ApiScope[],
  device: ["tenant:read", "device:register", "actions:run"] as ApiScope[],
  appOnly: ["actions:confirm", "shares:manage"] as ApiScope[],
  webhookManager: ["tenant:read", "webhook:manage"] as ApiScope[],
  // Deliberately the whole of a guest's authority: read the one resource the
  // credential is bound to. No publish, no actions:run, no actions:confirm —
  // holding a shared link must never let anyone act on someone else's account.
  guest: ["guest:read"] as ApiScope[],
  legacyPublisher: [
    "tenant:read",
    "publish",
    "device:register",
    "actions:run",
    "shares:manage",
    "webhook:manage",
  ] as ApiScope[],
} as const;

interface AuthRow {
  id: string;
  tenant_id: string;
  last_used_at: string | null;
  kind: CredentialKind;
  session_id: string | null;
  device_id: string | null;
  expires_at: string;
  scopes_json: string;
  renew_seconds: number | null;
  resource_kind: string | null;
  resource_id: string | null;
}

export interface TenantRecord {
  id: string;
  ownerEmail: string;
  createdAt: string;
  disabledAt?: string;
}

export interface ApiKeyRecord {
  id: string;
  tenantId: string;
  tokenHash: string;
  label: string;
  createdAt: string;
  lastUsedAt?: string;
  revokedAt?: string;
  kind: CredentialKind;
  sessionId?: string;
  deviceId?: string;
  expiresAt: string;
  scopes: ApiScope[];
  resourceKind?: string;
  resourceId?: string;
  /// Seconds of inactivity the credential tolerates before expiring. Undefined
  /// means a fixed deadline that use does not extend.
  renewSeconds?: number;
}

export interface CreateApiKeyInput {
  tenantId?: string;
  ownerEmail?: string;
  label?: string;
  kind?: CredentialKind;
  sessionId?: string;
  deviceId?: string;
  expiresAt?: string;
  scopes?: readonly ApiScope[];
  resourceKind?: string;
  resourceId?: string;
  /// Pass `null` for a credential whose deadline use should never extend.
  renewSeconds?: number | null;
}

export interface CreatedApiKey {
  tenant: TenantRecord;
  apiKey: ApiKeyRecord;
  token: string;
}

export async function requireAuth(
  req: Request,
  env: Env,
  options: { allowExpired?: boolean } = {},
): Promise<AuthContext> {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    throw new AuthError("missing or malformed Authorization header");
  }
  const apiKey = match[1].trim();
  if (!API_TOKEN_PATTERN.test(apiKey)) {
    throw new AuthError("invalid API key");
  }
  const apiKeyHash = await sha256Hex(apiKey);
  const sourceIp = req.headers.get("cf-connecting-ip")?.trim() || "unknown";
  const [sourceAllowed, tokenAllowed] = await Promise.all([
    checkAuthRateLimit(env.AUTH_SOURCE_LIMITER, `source:${sourceIp}`),
    checkAuthRateLimit(env.AUTH_TOKEN_LIMITER, `token:${apiKeyHash}`),
  ]);
  if (!sourceAllowed || !tokenAllowed) {
    throw new AuthRateLimitError();
  }
  const row = await env.ZW_DB.prepare(
    `SELECT api_keys.id, api_keys.tenant_id, api_keys.last_used_at,
            api_keys.kind, api_keys.session_id, api_keys.device_id, api_keys.expires_at,
            api_keys.scopes_json, api_keys.renew_seconds,
            api_keys.resource_kind, api_keys.resource_id
     FROM api_keys
     JOIN tenants ON tenants.id = api_keys.tenant_id
     WHERE api_keys.token_hash = ?
       AND api_keys.revoked_at IS NULL
       AND tenants.disabled_at IS NULL`,
  )
    .bind(apiKeyHash)
    .first<AuthRow>();
  if (!row) {
    throw new AuthError("invalid API key");
  }
  const expiresAtMs = Date.parse(row.expires_at);
  const expired = !Number.isFinite(expiresAtMs) || expiresAtMs <= Date.now();
  if (!options.allowExpired && expired) {
    throw new AuthError("API key expired");
  }
  const scopes = parseScopes(row.scopes_json);
  await touchApiKeyLastUsed(env, row, expired);
  return {
    apiKey,
    apiKeyHash,
    apiKeyId: row.id,
    tenantId: row.tenant_id,
    credentialKind: row.kind,
    sessionId: row.session_id ?? undefined,
    deviceId: row.device_id ?? undefined,
    expiresAt: row.expires_at,
    scopes,
    resourceKind: row.resource_kind ?? undefined,
    resourceId: row.resource_id ?? undefined,
  };
}

export class AuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}

export class AuthRateLimitError extends Error {
  constructor() {
    super("too many authentication attempts");
    this.name = "AuthRateLimitError";
  }
}

async function checkAuthRateLimit(limiter: RateLimit, key: string): Promise<boolean> {
  try {
    return (await limiter.limit({ key })).success;
  } catch (error) {
    // A transient limiter outage must not take the authenticated API offline.
    console.warn("authentication rate limiter unavailable", error);
    return true;
  }
}

/// Validates an API key against the comma-separated `API_KEYS` env var.
/// Used by the admin dashboard's API-token login path, which receives the
/// key in a form body rather than an Authorization header.
export function isValidApiKey(env: Env, provided: string): boolean {
  const trimmed = provided.trim();
  if (!trimmed) return false;
  if (!adminApiTokensAreSecure(env)) return false;
  const allowed = configuredAdminApiTokens(env);
  return allowed.some((k) => constantTimeEqual(k, trimmed));
}

/// Creates a tenant and nothing else — no credential, no session.
///
/// `createApiKey` also brings a tenant into existence as a side effect of
/// minting a key, which is right for the iOS app (it needs both) and wrong for
/// a web sign-up, where an account should exist before anything is issued
/// against it. Callers are responsible for deciding that signing up is
/// permitted; this function does not ask.
export async function createTenantForOwner(env: Env, ownerEmail: string): Promise<TenantRecord> {
  const email = normalizeEmail(ownerEmail);
  if (!email) throw new Error("ownerEmail is required");
  const now = new Date().toISOString();
  const id = crypto.randomUUID();
  await env.ZW_DB.prepare(
    `INSERT OR IGNORE INTO tenants (id, name, owner_email, created_at)
     VALUES (?, ?, ?, ?)`,
  )
    .bind(id, email, email, now)
    .run();
  return { id, ownerEmail: email, createdAt: now };
}

export async function createApiKey(env: Env, input: CreateApiKeyInput = {}): Promise<CreatedApiKey> {
  const now = new Date().toISOString();
  const tenantId = input.tenantId?.trim() || crypto.randomUUID();
  const existingTenant = input.tenantId
    ? await env.ZW_DB.prepare(
        `SELECT id, owner_email, created_at, disabled_at
         FROM tenants
         WHERE id = ?`,
      )
        .bind(tenantId)
        .first<{
          id: string;
          owner_email: string | null;
          created_at: string;
          disabled_at: string | null;
        }>()
    : null;
  const ownerEmail = normalizeEmail(existingTenant?.owner_email) || normalizeEmail(input.ownerEmail);
  if (!ownerEmail) {
    throw new Error("ownerEmail is required");
  }
  const label = input.label?.trim() || "default";
  const kind = input.kind ?? "publisher";
  const scopes = normalizeScopes(
    input.scopes ?? (kind === "app"
      ? ApiScopePresets.appOnly
      : kind === "guest"
        ? ApiScopePresets.guest
        : ApiScopePresets.producer),
  );
  const sessionId = input.sessionId?.trim() || undefined;
  const deviceId = input.deviceId?.trim() || undefined;
  const expiresAt = input.expiresAt
    ?? new Date(Date.now() + DEFAULT_TOKEN_LIFETIME_SECONDS * 1000).toISOString();
  if (!Number.isFinite(Date.parse(expiresAt)) || Date.parse(expiresAt) <= Date.now()) {
    throw new Error("expiresAt must be a future ISO-8601 timestamp");
  }
  // A guest link never renews on use. Sliding expiry on a bearer credential
  // that is printed on a QR code would let anyone holding it keep the link
  // alive indefinitely just by opening it, which defeats the fixed TTL that is
  // the main control on a link we cannot un-publish.
  const renewSeconds = kind === "guest"
    ? null
    : input.renewSeconds === undefined
      ? DEFAULT_TOKEN_LIFETIME_SECONDS
      : input.renewSeconds;
  if (renewSeconds !== null && (!Number.isInteger(renewSeconds) || renewSeconds <= 0)) {
    throw new Error("renewSeconds must be a positive integer or null");
  }
  const tokenPrefix = kind === "app" ? "zwa" : kind === "guest" ? "zwg" : "zw";
  const token = `${tokenPrefix}_${randomUrlToken(32)}`;
  const tokenHash = await sha256Hex(token);
  const apiKeyId = crypto.randomUUID();

  await env.ZW_DB.prepare(
    `INSERT OR IGNORE INTO tenants (id, name, owner_email, created_at)
     VALUES (?, ?, ?, ?)`,
  )
    .bind(tenantId, ownerEmail, ownerEmail, now)
    .run();
  await env.ZW_DB.prepare(
    `UPDATE tenants
     SET owner_email = ?
     WHERE id = ? AND (owner_email IS NULL OR owner_email = '')`,
  )
    .bind(ownerEmail, tenantId)
    .run();
  await env.ZW_DB.prepare(
    `INSERT INTO api_keys
       (id, tenant_id, token_hash, label, created_at, kind, session_id, device_id,
        expires_at, scopes_json, renew_seconds, resource_kind, resource_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      apiKeyId,
      tenantId,
      tokenHash,
      label,
      now,
      kind,
      sessionId ?? null,
      deviceId ?? null,
      expiresAt,
      JSON.stringify(scopes),
      renewSeconds,
      input.resourceKind ?? null,
      input.resourceId ?? null,
    )
    .run();

  return {
    tenant: {
      id: tenantId,
      ownerEmail,
      createdAt: existingTenant?.created_at ?? now,
      disabledAt: existingTenant?.disabled_at ?? undefined,
    },
    apiKey: {
      id: apiKeyId,
      tenantId,
      tokenHash,
      label,
      createdAt: now,
      kind,
      sessionId,
      deviceId,
      expiresAt,
      scopes,
      resourceKind: input.resourceKind,
      resourceId: input.resourceId,
      renewSeconds: renewSeconds ?? undefined,
    },
    token,
  };
}

export async function revokeApiKey(env: Env, id: string): Promise<boolean> {
  const now = new Date().toISOString();
  const result = await env.ZW_DB.prepare(
    `UPDATE api_keys
     SET revoked_at = ?
     WHERE id = ? AND revoked_at IS NULL`,
  )
    .bind(now, id)
    .run();
  return (result.meta as { changes?: number } | undefined)?.changes !== 0;
}

export async function listTenants(env: Env): Promise<TenantRecord[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT id, owner_email, created_at, disabled_at
     FROM tenants
     ORDER BY created_at DESC, owner_email`,
  ).all<{
    id: string;
    owner_email: string | null;
    created_at: string;
    disabled_at: string | null;
  }>();
  return rows.results.map((row) => ({
    id: row.id,
    ownerEmail: row.owner_email ?? "",
    createdAt: row.created_at,
    disabledAt: row.disabled_at ?? undefined,
  }));
}

export async function listApiKeys(env: Env): Promise<ApiKeyRecord[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at,
            kind, session_id, device_id, expires_at, scopes_json, renew_seconds,
            resource_kind, resource_id
     FROM api_keys
     ORDER BY created_at DESC`,
  ).all<{
    id: string;
    tenant_id: string;
    token_hash: string;
    label: string;
    created_at: string;
    last_used_at: string | null;
    revoked_at: string | null;
    kind: CredentialKind;
    session_id: string | null;
    device_id: string | null;
    expires_at: string;
    scopes_json: string;
    renew_seconds: number | null;
    resource_kind: string | null;
    resource_id: string | null;
  }>();
  return rows.results.map((row) => ({
    id: row.id,
    tenantId: row.tenant_id,
    tokenHash: row.token_hash,
    label: row.label,
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at ?? undefined,
    revokedAt: row.revoked_at ?? undefined,
    kind: row.kind,
    sessionId: row.session_id ?? undefined,
    deviceId: row.device_id ?? undefined,
    expiresAt: row.expires_at,
    scopes: parseScopes(row.scopes_json),
    resourceKind: row.resource_kind ?? undefined,
    resourceId: row.resource_id ?? undefined,
    renewSeconds: row.renew_seconds ?? undefined,
  }));
}

const GUEST_KEY_COLUMNS = `id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at,
            kind, session_id, device_id, expires_at, scopes_json, renew_seconds,
            resource_kind, resource_id`;

interface ApiKeyRow {
  id: string;
  tenant_id: string;
  token_hash: string;
  label: string;
  created_at: string;
  last_used_at: string | null;
  revoked_at: string | null;
  kind: CredentialKind;
  session_id: string | null;
  device_id: string | null;
  expires_at: string;
  scopes_json: string;
  renew_seconds: number | null;
  resource_kind: string | null;
  resource_id: string | null;
}

function rowToApiKeyRecord(row: ApiKeyRow): ApiKeyRecord {
  return {
    id: row.id,
    tenantId: row.tenant_id,
    tokenHash: row.token_hash,
    label: row.label,
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at ?? undefined,
    revokedAt: row.revoked_at ?? undefined,
    kind: row.kind,
    sessionId: row.session_id ?? undefined,
    deviceId: row.device_id ?? undefined,
    expiresAt: row.expires_at,
    scopes: parseScopes(row.scopes_json),
    resourceKind: row.resource_kind ?? undefined,
    resourceId: row.resource_id ?? undefined,
    renewSeconds: row.renew_seconds ?? undefined,
  };
}

/// One tenant's live guest links. Scoped in SQL rather than filtered in the
/// Worker: `listApiKeys` reads every row of every tenant, which is fine for the
/// admin dashboard and absurd for rendering one person's list of three links.
/// Hits `api_keys_by_tenant_kind`.
export async function listLiveGuestApiKeys(
  env: Env,
  tenantId: string,
): Promise<ApiKeyRecord[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT ${GUEST_KEY_COLUMNS}
     FROM api_keys
     WHERE tenant_id = ? AND kind = 'guest' AND revoked_at IS NULL AND expires_at > ?
     ORDER BY created_at DESC`,
  )
    .bind(tenantId, new Date().toISOString())
    .all<ApiKeyRow>();
  return rows.results.map(rowToApiKeyRecord);
}

export async function countLiveGuestApiKeys(env: Env, tenantId: string): Promise<number> {
  const row = await env.ZW_DB.prepare(
    `SELECT COUNT(*) AS total
     FROM api_keys
     WHERE tenant_id = ? AND kind = 'guest' AND revoked_at IS NULL AND expires_at > ?`,
  )
    .bind(tenantId, new Date().toISOString())
    .first<{ total: number }>();
  return row?.total ?? 0;
}

/// A single guest credential, scoped to its tenant so an id belonging to
/// somebody else is indistinguishable from one that never existed.
export async function getGuestApiKey(
  env: Env,
  tenantId: string,
  id: string,
): Promise<ApiKeyRecord | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT ${GUEST_KEY_COLUMNS}
     FROM api_keys
     WHERE id = ? AND tenant_id = ? AND kind = 'guest'`,
  )
    .bind(id, tenantId)
    .first<ApiKeyRow>();
  return row ? rowToApiKeyRecord(row) : null;
}

/// Deletes guest credentials that expired or were revoked more than a day ago.
///
/// Guest links are minted freely and never renew, so without this the table
/// grows for the life of the deployment. Only `kind = 'guest'` rows are
/// touched: a revoked publisher or app credential is account history, while a
/// lapsed guest link is litter. Opportunistic and fail-safe, in the manner of
/// the rate limiter's own bucket cleanup.
export async function pruneExpiredGuestApiKeys(env: Env): Promise<void> {
  const threshold = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  try {
    // Two statements rather than one OR: each matches a partial index, while
    // the disjunction forced SQLite to scan the whole table.
    await env.ZW_DB.batch([
      env.ZW_DB.prepare(
        `DELETE FROM api_keys WHERE kind = 'guest' AND expires_at < ?`,
      ).bind(threshold),
      env.ZW_DB.prepare(
        `DELETE FROM api_keys
         WHERE kind = 'guest' AND revoked_at IS NOT NULL AND revoked_at < ?`,
      ).bind(threshold),
    ]);
  } catch (err) {
    console.warn("guest_api_key.prune_failed", {
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

export function hasScope(auth: Pick<AuthContext, "scopes">, scope: ApiScope): boolean {
  return auth.scopes.includes(scope);
}

function normalizeScopes(scopes: readonly ApiScope[]): ApiScope[] {
  const allowed = new Set<ApiScope>(API_SCOPES);
  const normalized = [...new Set(scopes)];
  if (normalized.some((scope) => !allowed.has(scope))) {
    throw new Error("invalid API scope");
  }
  return API_SCOPES.filter((scope) => normalized.includes(scope));
}

function parseScopes(raw: string): ApiScope[] {
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed) || parsed.some((scope) => typeof scope !== "string")) {
      throw new Error("malformed scope list");
    }
    return normalizeScopes(parsed as ApiScope[]);
  } catch {
    throw new AuthError("invalid API key scopes");
  }
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

function normalizeEmail(email: string | null | undefined): string {
  return (email ?? "").trim().toLowerCase();
}

async function touchApiKeyLastUsed(
  env: Env,
  row: Pick<AuthRow, "id" | "last_used_at" | "renew_seconds">,
  expired: boolean,
): Promise<void> {
  const now = new Date();
  if (row.last_used_at) {
    const previousMs = Date.parse(row.last_used_at);
    if (Number.isFinite(previousMs) && now.getTime() - previousMs < TOUCH_THROTTLE_MS) return;
  }
  // Sliding expiry. Two cases never renew:
  //   renew_seconds NULL — the operator asked for a fixed deadline.
  //   expired            — a credential admitted only via `allowExpired` (the
  //                        sign-out route) must not be brought back to life.
  const renewSeconds = row.renew_seconds;
  const renews = !expired && typeof renewSeconds === "number" && renewSeconds > 0;
  try {
    if (renews) {
      const renewedTo = new Date(now.getTime() + renewSeconds * 1000).toISOString();
      // MAX() so renewal only ever pushes the deadline out — a longer expiry an
      // operator set by hand is never silently shortened to the sliding window.
      // Both sides are `YYYY-MM-DDTHH:mm:ss.sssZ`, which sorts lexicographically.
      await env.ZW_DB.prepare(
        `UPDATE api_keys
         SET last_used_at = ?, expires_at = MAX(expires_at, ?)
         WHERE id = ? AND revoked_at IS NULL`,
      )
        .bind(now.toISOString(), renewedTo, row.id)
        .run();
    } else {
      await env.ZW_DB.prepare(
        `UPDATE api_keys
         SET last_used_at = ?
         WHERE id = ? AND revoked_at IS NULL`,
      )
        .bind(now.toISOString(), row.id)
        .run();
    }
  } catch (err) {
    console.warn("api_key.last_used_update_failed", {
      apiKeyId: row.id,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

export async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomUrlToken(bytes: number): string {
  const data = new Uint8Array(bytes);
  crypto.getRandomValues(data);
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
