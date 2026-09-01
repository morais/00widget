import {
  AuthError,
  authenticateApiKey,
  type AuthContext,
  type CredentialKind,
} from "./auth";
import type { Env } from "./types";

interface ReviewCredentialRow {
  tenant_id: string;
  owner_email: string | null;
  kind: CredentialKind;
  expires_at: string;
  scopes_json: string;
}

export interface ReviewIdentity {
  tenantId: string;
  ownerEmail: string;
}

export function reviewTenantIds(env: Env): string[] {
  return [...new Set(
    (env.REVIEW_TENANT_IDS ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  )];
}

export function reviewLoginEnabled(env: Env): boolean {
  return reviewTenantIds(env).length > 0;
}

export function isReviewTenant(env: Env, tenantId: string): boolean {
  return reviewTenantIds(env).includes(tenantId);
}

export function isMcpAuthorizeNext(next: string | undefined): boolean {
  return next?.split("?", 1)[0] === "/connect/mcp/authorize";
}

/// A review access code is an ordinary, revocable API key with no API scopes.
/// It can prove identity only; the browser or app then receives credentials
/// through the same issuance paths as any other user.
export async function authenticateReviewAccessCode(
  req: Request,
  env: Env,
  accessCode: string,
): Promise<AuthContext> {
  const auth = await authenticateApiKey(req, env, accessCode.trim());
  if (!isReviewTenant(env, auth.tenantId)
      || auth.credentialKind !== "publisher"
      || auth.scopes.length !== 0
      || !auth.ownerEmail) {
    throw new AuthError("invalid review access code");
  }
  return auth;
}

/// Browser sessions keep only the access-code hash. Re-read the row for every
/// request so revoking the code or removing the tenant from configuration
/// ends the session immediately instead of waiting for its cookie to expire.
export async function resolveReviewAccessCodeHash(
  env: Env,
  tokenHash: string,
): Promise<ReviewIdentity | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT api_keys.tenant_id, tenants.owner_email, api_keys.kind,
            api_keys.expires_at, api_keys.scopes_json
     FROM api_keys
     JOIN tenants ON tenants.id = api_keys.tenant_id
     WHERE api_keys.token_hash = ?
       AND api_keys.revoked_at IS NULL
       AND tenants.disabled_at IS NULL`,
  )
    .bind(tokenHash)
    .first<ReviewCredentialRow>();
  if (!row || !isReviewTenant(env, row.tenant_id) || row.kind !== "publisher") return null;
  if (!row.owner_email || Date.parse(row.expires_at) <= Date.now()) return null;
  try {
    const scopes = JSON.parse(row.scopes_json) as unknown;
    if (!Array.isArray(scopes) || scopes.length !== 0) return null;
  } catch {
    return null;
  }
  return { tenantId: row.tenant_id, ownerEmail: row.owner_email };
}
