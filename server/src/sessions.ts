import type { AuthContext } from "./auth";
import { json } from "./http";
import type { Env } from "./types";

interface TokenHashRow {
  token_hash: string;
}

interface CredentialRow {
  id: string;
  tenant_id: string;
  token_hash: string;
  session_id: string | null;
  device_id: string | null;
}

interface RevocationTarget {
  apiKeyId: string;
  apiKeyHash: string;
  tenantId: string;
  sessionId?: string;
  deviceId?: string;
}

interface RevocationOutcome {
  revokedCredentials: number;
  removedRegistrations: number;
}

export async function revokeCurrentCredential(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const outcome = await revokeAndCleanup(env, auth);
  return json({ ok: true, ...outcome });
}

export async function revokeCredentialById(env: Env, apiKeyId: string): Promise<boolean> {
  const row = await env.ZW_DB.prepare(
    `SELECT id, tenant_id, token_hash, session_id, device_id
     FROM api_keys
     WHERE id = ?`,
  )
    .bind(apiKeyId)
    .first<CredentialRow>();
  if (!row) return false;

  const outcome = await revokeAndCleanup(env, {
    apiKeyId: row.id,
    apiKeyHash: row.token_hash,
    tenantId: row.tenant_id,
    sessionId: row.session_id ?? undefined,
    deviceId: row.device_id ?? undefined,
  });
  return outcome.revokedCredentials > 0;
}

async function revokeAndCleanup(
  env: Env,
  target: RevocationTarget,
): Promise<RevocationOutcome> {
  const now = new Date().toISOString();
  const hashes = target.sessionId
    ? await sessionTokenHashes(env, target.tenantId, target.sessionId)
    : [target.apiKeyHash];

  const statements: D1PreparedStatement[] = [];
  if (target.sessionId) {
    statements.push(
      env.ZW_DB.prepare(
        `UPDATE api_keys
         SET revoked_at = ?
         WHERE tenant_id = ? AND session_id = ? AND revoked_at IS NULL`,
      ).bind(now, target.tenantId, target.sessionId),
    );
  } else {
    statements.push(
      env.ZW_DB.prepare(
        `UPDATE api_keys
         SET revoked_at = ?
         WHERE id = ? AND revoked_at IS NULL`,
      ).bind(now, target.apiKeyId),
    );
  }

  for (const hash of hashes) addCleanupByHash(statements, env, target.tenantId, hash);
  if (target.deviceId) addCleanupByDevice(statements, env, target.tenantId, target.deviceId);

  const results = await env.ZW_DB.batch(statements);
  return {
    revokedCredentials: resultChanges(results[0]),
    removedRegistrations: results.slice(1).reduce((total, result) => total + resultChanges(result), 0),
  };
}

async function sessionTokenHashes(env: Env, tenantId: string, sessionId: string): Promise<string[]> {
  const rows = await env.ZW_DB.prepare(
    `SELECT token_hash
     FROM api_keys
     WHERE tenant_id = ? AND session_id = ?`,
  )
    .bind(tenantId, sessionId)
    .all<TokenHashRow>();
  return rows.results.map((row) => row.token_hash);
}

function addCleanupByHash(
  statements: D1PreparedStatement[],
  env: Env,
  tenantId: string,
  apiKeyHash: string,
): void {
  for (const table of ["devices", "widget_tokens", "start_tokens"]) {
    statements.push(
      env.ZW_DB.prepare(
        `DELETE FROM ${table} WHERE tenant_id = ? AND api_key_hash = ?`,
      ).bind(tenantId, apiKeyHash),
    );
  }
  statements.push(
    env.ZW_DB.prepare(
      `DELETE FROM activity_deliveries
       WHERE target_tenant_id = ? AND api_key_hash = ?`,
    ).bind(tenantId, apiKeyHash),
  );
}

function addCleanupByDevice(
  statements: D1PreparedStatement[],
  env: Env,
  tenantId: string,
  deviceId: string,
): void {
  for (const table of ["devices", "widget_tokens", "start_tokens"]) {
    statements.push(
      env.ZW_DB.prepare(
        `DELETE FROM ${table} WHERE tenant_id = ? AND device_id = ?`,
      ).bind(tenantId, deviceId),
    );
  }
  statements.push(
    env.ZW_DB.prepare(
      `DELETE FROM activity_deliveries
       WHERE target_tenant_id = ? AND device_id = ?`,
    ).bind(tenantId, deviceId),
  );
}

function resultChanges(result: D1Result): number {
  return (result.meta as { changes?: number } | undefined)?.changes ?? 0;
}
