import {
  appAppleLoginConfigured,
  validateAppleIdTokenForAudience,
} from "./appleAuth";
import { createApiKey } from "./auth";
import { parseJson } from "./cards";
import { json } from "./http";
import { appleSubKey, enforceRateLimits } from "./rateLimit";
import { FieldLimits, RequestBodyLimits, type Env } from "./types";

interface AppleTokenRequest {
  identityToken?: string;
  label?: string;
}

export async function createTokenFromApple(req: Request, env: Env): Promise<Response> {
  if (!appAppleLoginConfigured(env)) {
    return json({ error: "Apple app login is not enabled" }, 404);
  }

  let input: AppleTokenRequest;
  try {
    input = (await parseJson(req, RequestBodyLimits.appleLogin)) as AppleTokenRequest;
  } catch {
    return json({ error: "missing JSON body" }, 400);
  }
  if (!input || typeof input !== "object") return json({ error: "missing JSON body" }, 400);

  const identityToken = input.identityToken?.trim();
  if (!identityToken) return json({ error: "identityToken is required" }, 400);
  if (identityToken.length > FieldLimits.appleIdentityToken) {
    return json({ error: "identityToken is too large" }, 400);
  }
  if (input.label && input.label.length > FieldLimits.apiKeyLabel) {
    return json({ error: "label is too large" }, 400);
  }

  let claims: Awaited<ReturnType<typeof validateAppleIdTokenForAudience>>;
  try {
    claims = await validateAppleIdTokenForAudience(
      env,
      identityToken,
      env.APPLE_APP_SIGN_IN_CLIENT_ID,
    );
  } catch (err) {
    return json({ error: `token validation failed: ${(err as Error).message}` }, 401);
  }
  const limited = await enforceRateLimits(env, [
    { policy: "appleLoginSubHour", key: appleSubKey(claims.sub) },
  ]);
  if (limited) return limited;

  const email = claims.email?.trim().toLowerCase();
  const existingAccount = await getAppleAccount(env, claims.sub);
  if (!email && !existingAccount) {
    return json({ error: "Apple did not return an email for this sign-in" }, 403);
  }
  if (email && !isEmailVerified(claims.email_verified)) {
    return json({ error: "Apple email is not verified" }, 403);
  }
  const existingTenant = existingAccount
    ? null
    : await getTenantByOwnerEmail(env, email);
  const tenantId = existingAccount?.tenantId ?? existingTenant?.id;
  const ownerEmail = existingAccount?.email ?? existingTenant?.email ?? email;

  const created = await createApiKey(env, {
    tenantId,
    ownerEmail,
    label: input.label?.trim() || "iOS app",
  });
  await putAppleAccount(env, {
    appleSub: claims.sub,
    tenantId: created.tenant.id,
    email: email ?? existingAccount!.email,
  });
  return json(created, 201);
}

function isEmailVerified(value: boolean | string | undefined): boolean {
  return value === true || value === "true";
}

interface AppleAccountRecord {
  appleSub: string;
  tenantId: string;
  email: string;
}

interface TenantEmailRecord {
  id: string;
  email: string;
}

async function getAppleAccount(env: Env, appleSub: string): Promise<AppleAccountRecord | null> {
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

async function getTenantByOwnerEmail(
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

async function putAppleAccount(env: Env, record: AppleAccountRecord): Promise<void> {
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
