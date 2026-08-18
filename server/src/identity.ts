import type { Env } from "./types";

// Who a sign-in belongs to, resolved the same way wherever it happens.
//
// The iOS app and the web sign-in reach this from different directions and must
// land on the same tenant. Apple's `sub` is the reliable join: it is stable per
// person per app family, survives an email change, and is what `apple_accounts`
// is keyed on. Email is the fallback for an account created before that row
// existed, or for a tenant an operator provisioned by hand.
//
// Nothing here creates anything. A caller that wants to sign someone up says so
// explicitly — see `appLogin.ts`, which is the only place a tenant is born.

export interface AppleAccountRecord {
  appleSub: string;
  tenantId: string;
  email: string;
}

export interface TenantEmailRecord {
  id: string;
  email: string;
}

export interface ResolvedIdentity {
  tenantId: string;
  ownerEmail: string;
}

/// The tenant this person already owns, or null if they have never signed up.
export async function resolveIdentity(
  env: Env,
  identity: { appleSub?: string; email?: string },
): Promise<ResolvedIdentity | null> {
  const account = identity.appleSub ? await getAppleAccount(env, identity.appleSub) : null;
  if (account) return { tenantId: account.tenantId, ownerEmail: account.email };
  const tenant = await getTenantByOwnerEmail(env, identity.email?.trim().toLowerCase());
  return tenant ? { tenantId: tenant.id, ownerEmail: tenant.email } : null;
}

export async function getAppleAccount(env: Env, appleSub: string): Promise<AppleAccountRecord | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT apple_sub, tenant_id, email
     FROM apple_accounts
     WHERE apple_sub = ?`,
  )
    .bind(appleSub)
    .first<{ apple_sub: string; tenant_id: string; email: string }>();
  return row
    ? { appleSub: row.apple_sub, tenantId: row.tenant_id, email: row.email }
    : null;
}

export async function getTenantByOwnerEmail(
  env: Env,
  email: string | undefined,
): Promise<TenantEmailRecord | null> {
  if (!email) return null;
  const row = await env.ZW_DB.prepare(
    `SELECT id, owner_email
     FROM tenants
     WHERE lower(owner_email) = ?
       AND disabled_at IS NULL
     ORDER BY created_at ASC
     LIMIT 1`,
  )
    .bind(email)
    .first<{ id: string; owner_email: string }>();
  return row ? { id: row.id, email: row.owner_email } : null;
}

export async function putAppleAccount(env: Env, record: AppleAccountRecord): Promise<void> {
  const now = new Date().toISOString();
  await env.ZW_DB.prepare(
    `INSERT INTO apple_accounts (apple_sub, tenant_id, email, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(apple_sub) DO UPDATE SET
       tenant_id = excluded.tenant_id,
       email = excluded.email,
       updated_at = excluded.updated_at`,
  )
    .bind(record.appleSub, record.tenantId, record.email, now, now)
    .run();
}
