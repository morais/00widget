import type { Env } from "./types";

export interface AuthContext {
  apiKey: string;
  apiKeyHash: string;
  apiKeyId: string;
  tenantId: string;
}

interface AuthRow {
  id: string;
  tenant_id: string;
  last_used_at: string | null;
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
}

export interface CreateApiKeyInput {
  tenantId?: string;
  ownerEmail?: string;
  label?: string;
}

export interface CreatedApiKey {
  tenant: TenantRecord;
  apiKey: ApiKeyRecord;
  token: string;
}

export async function requireAuth(req: Request, env: Env): Promise<AuthContext> {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    throw new AuthError("missing or malformed Authorization header");
  }
  const apiKey = match[1].trim();
  const apiKeyHash = await sha256Hex(apiKey);
  const row = await env.ZW_DB.prepare(
    `SELECT api_keys.id, api_keys.tenant_id, api_keys.last_used_at
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
  await touchApiKeyLastUsed(env, row.id, row.last_used_at);
  return { apiKey, apiKeyHash, apiKeyId: row.id, tenantId: row.tenant_id };
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
  const token = `zw_${randomUrlToken(32)}`;
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
    `INSERT INTO api_keys (id, tenant_id, token_hash, label, created_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(apiKeyId, tenantId, tokenHash, label, now)
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
    `SELECT id, tenant_id, token_hash, label, created_at, last_used_at, revoked_at
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
  }>();
  return rows.results.map((row) => ({
    id: row.id,
    tenantId: row.tenant_id,
    tokenHash: row.token_hash,
    label: row.label,
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at ?? undefined,
    revokedAt: row.revoked_at ?? undefined,
  }));
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
