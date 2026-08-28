import type { AuthContext } from "./auth";
import {
  getMcpConnection,
  listLiveMcpConnections,
  revokeApiKey,
} from "./auth";
import { json, notFound } from "./http";
import type { Env } from "./types";

/// GET /v1/account/mcp-connections — active OAuth grants owned by this
/// account. Tokens and hashes never leave the server.
export async function listMcpConnections(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const connections = (await listLiveMcpConnections(env, auth.tenantId))
    .map((connection) => ({
      id: connection.id,
      clientName: clientNameFromLabel(connection.label),
      connectedAt: connection.createdAt,
      lastUsedAt: connection.lastUsedAt,
      expiresAt: connection.expiresAt,
      scopes: connection.scopes,
    }));
  return json({ connections });
}

/// DELETE /v1/account/mcp-connections/:id — revokes one grant. It does not and
/// cannot remove the connector from the remote host's own UI; the next call is
/// rejected and reconnecting requires a fresh approval.
export async function disconnectMcpConnection(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
): Promise<Response> {
  // Tenant and purpose are checked before the id reaches the generic revoke
  // helper, so another account's credential and a non-connector credential are
  // both indistinguishable from an id that never existed.
  const connection = await getMcpConnection(env, auth.tenantId, id);
  if (!connection) return notFound();
  const revoked = await revokeApiKey(env, id);
  return json({ ok: true, revoked });
}

/// OAuth labels currently read "MCP · <client name> · <approver email>" for
/// the admin audit trail. The account app needs the client name but must not
/// receive the email. A client name may itself contain the separator, so peel
/// only the last component.
function clientNameFromLabel(label: string): string {
  const prefix = "MCP · ";
  if (!label.startsWith(prefix)) return label || "MCP client";
  const rest = label.slice(prefix.length);
  const lastSeparator = rest.lastIndexOf(" · ");
  const name = (lastSeparator >= 0 ? rest.slice(0, lastSeparator) : rest).trim();
  return name || "MCP client";
}
