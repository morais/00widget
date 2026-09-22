import { ApiScopePresets, createApiKey, sha256Hex } from "./auth";
import { parseJson } from "./cards";
import { createVerifiedHorizonAuthorization } from "./deviceAuth";
import { badRequest, json, notFound } from "./http";
import { enforceRateLimits } from "./rateLimit";
import { FieldLimits, RequestBodyLimits, type Env } from "./types";

const META_USER_PROOF_URL = "https://graph.oculus.com/user_nonce_validate";
const PROOF_REPLAY_TTL_MS = 10 * 60 * 1000;
const HORIZON_ACCOUNT_NAME = "Horizon account";

interface HorizonLoginRequest {
  userId?: unknown;
  userProof?: unknown;
  choice?: unknown;
  deviceId?: unknown;
}

interface HorizonAccountRow {
  tenant_id: string;
}

export function horizonIdentityEnabled(env: Env): boolean {
  return env.HORIZON_IDENTITY_ENABLED === "true";
}

/// POST /v1/auth/horizon — prove the Meta identity, then either sign in to its
/// existing tenant or ask the client to make an explicit create/join choice.
/// A new UserProof is needed for each attempt; verified nonces are single-use.
export async function signInWithHorizon(req: Request, env: Env): Promise<Response> {
  if (!horizonIdentityEnabled(env)) return notFound();
  const appId = env.META_APP_ID?.trim();
  const appSecret = env.META_APP_SECRET?.trim();
  if (!appId || !appSecret) return json({ error: "Horizon identity is not configured" }, 503);

  let input: HorizonLoginRequest;
  try {
    input = (await parseJson(req, RequestBodyLimits.horizonAuth)) as HorizonLoginRequest;
  } catch {
    return badRequest("missing JSON body");
  }
  if (!input || typeof input !== "object") return badRequest("missing JSON body");
  const userId = typeof input.userId === "string" ? input.userId.trim() : "";
  const userProof = typeof input.userProof === "string" ? input.userProof.trim() : "";
  const deviceId = typeof input.deviceId === "string" ? input.deviceId.trim() : "";
  const choice = input.choice === undefined ? undefined : input.choice;
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(userId)) return badRequest("userId is invalid");
  if (userProof.length < 8 || userProof.length > 1024 || /[\x00-\x1f\x7f]/.test(userProof)) {
    return badRequest("userProof is invalid");
  }
  if (deviceId.length > FieldLimits.deviceId) return badRequest("deviceId is too large");
  if (choice !== undefined && choice !== "create" && choice !== "join_apple") {
    return badRequest("choice must be create or join_apple");
  }

  const limited = await enforceRateLimits(env, [
    { policy: "horizonLoginIpHour", key: `horizon-login:${req.headers.get("cf-connecting-ip")?.trim() || "unknown"}` },
  ]);
  if (limited) return limited;

  let verified: boolean;
  try {
    const response = await fetch(META_USER_PROOF_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({
        access_token: `OC|${appId}|${appSecret}`,
        nonce: userProof,
        user_id: userId,
      }),
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) {
      return response.status >= 500
        ? json({ error: "Meta verification is unavailable" }, 502)
        : json({ error: "Meta could not verify this user" }, 401);
    }
    const body = await response.json() as { is_valid?: unknown };
    verified = body.is_valid === true;
  } catch {
    return json({ error: "Meta verification is unavailable" }, 502);
  }
  if (!verified) return json({ error: "Meta could not verify this user" }, 401);

  const now = new Date();
  const proofHash = await sha256Hex(`${appId}:${userId}:${userProof}`);
  const used = await env.ZW_DB.prepare(
    `INSERT OR IGNORE INTO horizon_proof_uses (nonce_hash, expires_at) VALUES (?, ?)`,
  )
    .bind(proofHash, new Date(now.getTime() + PROOF_REPLAY_TTL_MS).toISOString())
    .run();
  if (changedRows(used) === 0) return json({ error: "User proof has already been used" }, 409);
  // The table is tiny, but old proof hashes must not become permanent account
  // data. Expiry removes only a bearer replay guard, never an identity.
  await env.ZW_DB.prepare(`DELETE FROM horizon_proof_uses WHERE expires_at < ?`)
    .bind(now.toISOString())
    .run();

  const account = await getHorizonAccount(env, appId, userId);
  if (account) return issueHorizonCredential(env, account.tenant_id, deviceId);
  if (choice === undefined) {
    return json({ status: "choice_required", choices: ["create", "join_apple"] }, 200, {
      "cache-control": "no-store",
    });
  }
  if (choice === "join_apple") {
    return createVerifiedHorizonAuthorization(req, env, appId, userId);
  }

  const tenantId = crypto.randomUUID();
  const createdAt = now.toISOString();
  try {
    // D1 batches are transactions. A concurrent signup for the same Meta ID
    // rolls the new tenant back when the unique horizon_accounts key loses.
    await env.ZW_DB.batch([
      env.ZW_DB.prepare(
        `INSERT INTO tenants (id, name, owner_email, created_at) VALUES (?, ?, NULL, ?)`,
      ).bind(tenantId, HORIZON_ACCOUNT_NAME, createdAt),
      env.ZW_DB.prepare(
        `INSERT INTO horizon_accounts (app_id, user_id, tenant_id, created_at)
         VALUES (?, ?, ?, ?)`,
      ).bind(appId, userId, tenantId, createdAt),
    ]);
  } catch (error) {
    const winner = await getHorizonAccount(env, appId, userId);
    if (!winner) throw error;
    return issueHorizonCredential(env, winner.tenant_id, deviceId);
  }
  return issueHorizonCredential(env, tenantId, deviceId);
}

export async function getHorizonAccount(
  env: Env,
  appId: string,
  userId: string,
): Promise<HorizonAccountRow | null> {
  return env.ZW_DB.prepare(
    `SELECT tenant_id FROM horizon_accounts WHERE app_id = ? AND user_id = ?`,
  )
    .bind(appId, userId)
    .first<HorizonAccountRow>();
}

export async function getHorizonUserForTenant(env: Env, tenantId: string): Promise<string | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT user_id FROM horizon_accounts WHERE tenant_id = ?`,
  )
    .bind(tenantId)
    .first<{ user_id: string }>();
  return row?.user_id ?? null;
}

async function issueHorizonCredential(
  env: Env,
  tenantId: string,
  deviceId: string,
): Promise<Response> {
  const created = await createApiKey(env, {
    tenantId,
    label: "Horizon OS",
    kind: "app",
    purpose: "device",
    scopes: ApiScopePresets.device,
    deviceId: deviceId || undefined,
  });
  return json({ status: "signed_in", token: created.token }, 201, { "cache-control": "no-store" });
}

function changedRows(result: D1Result): number {
  return (result.meta as { changes?: number } | undefined)?.changes ?? 0;
}
