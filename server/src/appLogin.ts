import {
  appAppleLoginConfigured,
  validateAppleIdTokenForAudience,
} from "./appleAuth";
import { ApiScopePresets, createApiKey, sha256Hex } from "./auth";
import { parseJson } from "./cards";
import { json } from "./http";
import { appleSubKey, enforceRateLimits } from "./rateLimit";
import { FieldLimits, RequestBodyLimits, type Env } from "./types";

// Caller-supplied nonce — bounded length, anything else lets the client be
// the source of truth on encoding (hex, base64url, UUID, etc.).
const NONCE_MIN_LENGTH = 16;
const NONCE_MAX_LENGTH = 256;

interface AppleTokenRequest {
  identityToken?: string;
  label?: string;
  // Raw nonce the client passed (already hashed) to Sign in with Apple. We
  // re-hash and compare to the id_token's `nonce` claim to block replay of a
  // leaked identity token from a different login attempt.
  nonce?: string;
  deviceId?: string;
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
  if (input.deviceId && input.deviceId.length > FieldLimits.deviceId) {
    return json({ error: "deviceId is too large" }, 400);
  }

  const rawNonce = input.nonce?.trim();
  if (!rawNonce) return json({ error: "nonce is required" }, 400);
  if (rawNonce.length < NONCE_MIN_LENGTH || rawNonce.length > NONCE_MAX_LENGTH) {
    return json({ error: "nonce is malformed" }, 400);
  }

  const ipLimited = await enforceRateLimits(env, [
    { policy: "appleLoginIpHour", key: appleLoginIpKey(req) },
  ]);
  if (ipLimited) return ipLimited;

  // The iOS client hashes `rawNonce` with SHA-256 before handing it to
  // ASAuthorizationAppleIDRequest, so Apple's id_token contains the hex hash
  // in its `nonce` claim. We recompute the same hash and let
  // `validateAppleIdTokenForAudience` do the constant-time comparison.
  const expectedNonceHash = await sha256Hex(rawNonce);

  let claims: Awaited<ReturnType<typeof validateAppleIdTokenForAudience>>;
  try {
    claims = await validateAppleIdTokenForAudience(
      env,
      identityToken,
      env.APPLE_APP_SIGN_IN_CLIENT_ID,
      expectedNonceHash,
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

  const sessionId = crypto.randomUUID();
  const label = input.label?.trim() || "iOS app";
  const deviceId = input.deviceId?.trim() || undefined;
  const created = await createApiKey(env, {
    tenantId,
    ownerEmail,
    label,
    kind: "publisher",
    sessionId,
    deviceId,
    scopes: ApiScopePresets.device,
  });
  const appCredential = await createApiKey(env, {
    tenantId: created.tenant.id,
    ownerEmail: created.tenant.ownerEmail,
    label: `${label} (app only)`,
    kind: "app",
    sessionId,
    deviceId,
    scopes: ApiScopePresets.appOnly,
  });
  const publisherCredential = await createApiKey(env, {
    tenantId: created.tenant.id,
    ownerEmail: created.tenant.ownerEmail,
    label: `${label} (agent publisher)`,
    kind: "publisher",
    sessionId,
    deviceId,
    scopes: ApiScopePresets.producer,
  });
  await putAppleAccount(env, {
    appleSub: claims.sub,
    tenantId: created.tenant.id,
    email: email ?? existingAccount!.email,
  });
  return json({
    ...created,
    appCredential: appCredential.token,
    publisherCredential: publisherCredential.token,
  }, 201);
}

function appleLoginIpKey(req: Request): string {
  const ip = req.headers.get("cf-connecting-ip")?.trim();
  return `apple-login:${ip || "unknown"}`;
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
