import type { Env } from "./types";

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
}

export type CredentialKind = "publisher" | "app";

export const API_SCOPES = [
  "tenant:read",
  "publish",
  "device:register",
  "actions:run",
  "actions:confirm",
  "shares:manage",
  "webhook:manage",
] as const;

export type ApiScope = typeof API_SCOPES[number];

export const ApiScopePresets = {
  producer: ["tenant:read", "publish"] as ApiScope[],
  readOnly: ["tenant:read"] as ApiScope[],
  device: ["tenant:read", "device:register", "actions:run"] as ApiScope[],
  appOnly: ["actions:confirm", "shares:manage"] as ApiScope[],
  webhookManager: ["tenant:read", "webhook:manage"] as ApiScope[],
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
  const apiKeyHash = await sha256Hex(apiKey);
  const row = await env.ZW_DB.prepare(
    `SELECT api_keys.id, api_keys.tenant_id, api_keys.last_used_at,
            api_keys.kind, api_keys.session_id, api_keys.device_id, api_keys.expires_at,
            api_keys.scopes_json
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
  if (!options.allowExpired && (!Number.isFinite(expiresAtMs) || expiresAtMs <= Date.now())) {
    throw new AuthError("API key expired");
  }
  const scopes = parseScopes(row.scopes_json);
  await touchApiKeyLastUsed(env, row.id, row.last_used_at);
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
  };
}

export class AuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}

/// Validates an API key against the comma-separated `API_KEYS` env var.
/// Used by the admin dashboard's API-token login path, which receives the
/// key in a form body rather than an Authorization header.
export function isValidApiKey(env: Env, provided: string): boolean {
  const trimmed = provided.trim();
  if (!trimmed) return false;
  const allowed = (env.API_KEYS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (allowed.length === 0) return false;
  return allowed.some((k) => constantTimeEqual(k, trimmed));
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
    input.scopes ?? (kind === "app" ? ApiScopePresets.appOnly : ApiScopePresets.producer),
  );
  const sessionId = input.sessionId?.trim() || undefined;
  const deviceId = input.deviceId?.trim() || undefined;
  const expiresAt = input.expiresAt ?? new Date(Date.now() + 90 * 24 * 60 * 60 * 1000).toISOString();
  if (!Number.isFinite(Date.parse(expiresAt)) || Date.parse(expiresAt) <= Date.now()) {
    throw new Error("expiresAt must be a future ISO-8601 timestamp");
  }
  const token = `${kind === "app" ? "zwa" : "zw"}_${randomUrlToken(32)}`;
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
        expires_at, scopes_json)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
            kind, session_id, device_id, expires_at, scopes_json
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
  }));
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
  apiKeyId: string,
  previous: string | null,
): Promise<void> {
  const now = new Date();
  if (previous) {
    const previousMs = Date.parse(previous);
    if (Number.isFinite(previousMs) && now.getTime() - previousMs < 60 * 60 * 1000) return;
  }
  try {
    await env.ZW_DB.prepare(
      `UPDATE api_keys
       SET last_used_at = ?
       WHERE id = ? AND revoked_at IS NULL`,
    )
      .bind(now.toISOString(), apiKeyId)
      .run();
  } catch (err) {
    console.warn("api_key.last_used_update_failed", {
      apiKeyId,
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
