import {
  appAppleLoginConfigured,
  isAppleEmailVerified,
  validateAppleIdTokenForAudience,
} from "./appleAuth";
import { sha256Hex } from "./auth";
import { issueAppCredentialBundle } from "./appCredentials";
import { parseJson } from "./cards";
import { getAppleAccount, getTenantByOwnerEmail, putAppleAccount } from "./identity";
import { json } from "./http";
import { appleSubKey, enforceRateLimits } from "./rateLimit";
import { sendNewTenantAlert } from "./signupAlert";
import { FieldLimits, RequestBodyLimits, isValidEmail, type Env } from "./types";

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
  /// tvOS has no Agent-config surface, so it asks for only the two credentials
  /// the television itself needs. iOS defaults to issuing an account-level
  /// Agent-config token for compatibility with older builds.
  issuePublisherCredential?: boolean;
}

export async function createTokenFromApple(
  req: Request,
  env: Env,
  ctx?: ExecutionContext,
): Promise<Response> {
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
  if (email && !isAppleEmailVerified(claims.email_verified)) {
    return json({ error: "Apple email is not verified" }, 403);
  }
  // Apple is not expected to assert a malformed address, and this costs
  // nothing to be sure of. The claim becomes a tenant's owner_email, which
  // joins later sign-ins to this account and is interpolated into RFC 5322
  // headers by the signup alert — a control character in it would be a header
  // injection, and it is not this module's job to trust an upstream for that.
  if (email && !isValidEmail(email)) {
    return json({ error: "Apple returned an email this server cannot accept" }, 403);
  }
  const existingTenant = existingAccount
    ? null
    : await getTenantByOwnerEmail(env, email);
  // Neither an Apple account nor a tenant owning this email means createApiKey
  // is about to mint a fresh tenant id, rather than attaching this sign-in to
  // one that already exists. This is the only place that distinction is known:
  // createApiKey uses INSERT OR IGNORE and cannot report which happened.
  const isNewTenant = !existingAccount && !existingTenant;
  const tenantId = existingAccount?.tenantId ?? existingTenant?.id;
  const ownerEmail = existingAccount?.email ?? existingTenant?.email ?? email;

  const label = input.label?.trim() || "iOS app";
  const deviceId = input.deviceId?.trim() || undefined;
  const created = await issueAppCredentialBundle(env, {
    tenantId,
    ownerEmail: ownerEmail!,
    label,
    deviceId,
    issuePublisherCredential: input.issuePublisherCredential,
  });
  await putAppleAccount(env, {
    appleSub: claims.sub,
    tenantId: created.tenant.id,
    email: email ?? existingAccount!.email,
  });
  if (isNewTenant) {
    const alert = sendNewTenantAlert(env, {
      source: "app",
      tenantId: created.tenant.id,
      ownerEmail: created.tenant.ownerEmail,
      createdAt: created.tenant.createdAt,
    });
    // After the response, so a slow or failing mail send cannot delay signup.
    // Guard on the method, not the object: callers legitimately pass a partial
    // ExecutionContext, and a missing waitUntil must fall back rather than throw.
    if (typeof ctx?.waitUntil === "function") ctx.waitUntil(alert); else await alert;
  }
  return json(created, 201);
}

function appleLoginIpKey(req: Request): string {
  const ip = req.headers.get("cf-connecting-ip")?.trim();
  return `apple-login:${ip || "unknown"}`;
}


