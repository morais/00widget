import type { Env, ShareResourceKind } from "./types";
import { CreateShareSchema } from "./types";
import { json, badRequest, notFound } from "./http";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";

export interface ShareRecord {
  id: string;
  ownerTenantId: string;
  recipientTenantId?: string;
  recipientEmail: string;
  resourceKind: ShareResourceKind;
  resourceId: string;
  status: "pending" | "accepted" | "revoked" | "declined";
  createdAt: string;
  acceptedAt?: string;
  revokedAt?: string;
  // Optional decoration for outgoing/incoming list responses.
  ownerEmail?: string;
}

export function isSharingEnabled(env: Env): boolean {
  return (env.SHARING_ENABLED ?? "").trim().toLowerCase() === "true";
}

export function sharingDisabledResponse(): Response {
  return json({ error: "sharing is disabled" }, 503);
}

interface ShareRow {
  id: string;
  owner_tenant_id: string;
  recipient_tenant_id: string | null;
  recipient_email: string;
  resource_kind: string;
  resource_id: string;
  status: string;
  created_at: string;
  accepted_at: string | null;
  revoked_at: string | null;
}

function rowToRecord(row: ShareRow, decoration: { ownerEmail?: string } = {}): ShareRecord {
  return {
    id: row.id,
    ownerTenantId: row.owner_tenant_id,
    recipientTenantId: row.recipient_tenant_id ?? undefined,
    recipientEmail: row.recipient_email,
    resourceKind: row.resource_kind as ShareResourceKind,
    resourceId: row.resource_id,
    status: row.status as ShareRecord["status"],
    createdAt: row.created_at,
    acceptedAt: row.accepted_at ?? undefined,
    revokedAt: row.revoked_at ?? undefined,
    ownerEmail: decoration.ownerEmail,
  };
}

function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

export async function tenantOwnerEmail(env: Env, tenantId: string): Promise<string | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT owner_email FROM tenants WHERE id = ?`,
  )
    .bind(tenantId)
    .first<{ owner_email: string | null }>();
  return row?.owner_email ? normalizeEmail(row.owner_email) : null;
}

async function findTenantByEmail(env: Env, email: string): Promise<string | null> {
  const row = await env.ZW_DB.prepare(
    `SELECT id, owner_email FROM tenants WHERE lower(owner_email) = ? AND disabled_at IS NULL ORDER BY created_at ASC LIMIT 1`,
  )
    .bind(email)
    .first<{ id: string }>();
  return row?.id ?? null;
}

async function getShare(env: Env, id: string): Promise<ShareRow | null> {
  return await env.ZW_DB.prepare(
    `SELECT id, owner_tenant_id, recipient_tenant_id, recipient_email,
            resource_kind, resource_id, status, created_at, accepted_at, revoked_at
     FROM shares WHERE id = ?`,
  )
    .bind(id)
    .first<ShareRow>();
}

export async function createShare(req: Request, env: Env, auth: AuthContext): Promise<Response> {
  if (!isSharingEnabled(env)) return sharingDisabledResponse();
  const body = await parseJson(req);
  const parsed = CreateShareSchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);

  const ownerEmail = await tenantOwnerEmail(env, auth.tenantId);
  if (!ownerEmail) return badRequest("set an account email before sharing");

  const recipientEmail = normalizeEmail(parsed.data.recipientEmail);
  if (recipientEmail === ownerEmail) {
    return badRequest("cannot share with yourself");
  }

  // Verify the resource exists and belongs to the caller.
  if (parsed.data.resourceKind === "card") {
    const card = await env.ZW_DB.prepare(
      `SELECT id FROM cards WHERE tenant_id = ? AND id = ?`,
    )
      .bind(auth.tenantId, parsed.data.resourceId)
      .first<{ id: string }>();
    if (!card) return notFound();
  }
  // For activity_kind we accept any string; the kind is owner-namespaced via
  // tenant scoping at fanout time, so existence isn't required up-front.

  // Reject duplicates that are still active. We treat (owner, recipient_email,
  // kind, id) with status in (pending, accepted) as a unique key.
  const existing = await env.ZW_DB.prepare(
    `SELECT id, status FROM shares
     WHERE owner_tenant_id = ?
       AND lower(recipient_email) = ?
       AND resource_kind = ?
       AND resource_id = ?
       AND status IN ('pending', 'accepted')
     LIMIT 1`,
  )
    .bind(auth.tenantId, recipientEmail, parsed.data.resourceKind, parsed.data.resourceId)
    .first<{ id: string; status: string }>();
  if (existing) {
    return json({ error: "already shared", id: existing.id, status: existing.status }, 409);
  }

  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const recipientTenantId = await findTenantByEmail(env, recipientEmail);

  await env.ZW_DB.prepare(
    `INSERT INTO shares
       (id, owner_tenant_id, recipient_tenant_id, recipient_email,
        resource_kind, resource_id, status, created_at)
     VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)`,
  )
    .bind(
      id,
      auth.tenantId,
      recipientTenantId,
      recipientEmail,
      parsed.data.resourceKind,
      parsed.data.resourceId,
      now,
    )
    .run();

  const row = await getShare(env, id);
  return json({ share: row ? rowToRecord(row) : null }, 201);
}

export async function listOutgoing(_req: Request, env: Env, auth: AuthContext): Promise<Response> {
  if (!isSharingEnabled(env)) return sharingDisabledResponse();
  const rows = await env.ZW_DB.prepare(
    `SELECT id, owner_tenant_id, recipient_tenant_id, recipient_email,
            resource_kind, resource_id, status, created_at, accepted_at, revoked_at
     FROM shares
     WHERE owner_tenant_id = ?
     ORDER BY created_at DESC`,
  )
    .bind(auth.tenantId)
    .all<ShareRow>();
  return json({ shares: rows.results.map((r) => rowToRecord(r)) });
}

export async function listIncoming(_req: Request, env: Env, auth: AuthContext): Promise<Response> {
  if (!isSharingEnabled(env)) return sharingDisabledResponse();
  const ownerEmail = await tenantOwnerEmail(env, auth.tenantId);
  if (!ownerEmail) return json({ shares: [] });

  // Match either by recipient_tenant_id (already linked) or by recipient_email
  // (for invites that arrived before the recipient signed up).
  const rows = await env.ZW_DB.prepare(
    `SELECT shares.id AS id,
            shares.owner_tenant_id AS owner_tenant_id,
            shares.recipient_tenant_id AS recipient_tenant_id,
            shares.recipient_email AS recipient_email,
            shares.resource_kind AS resource_kind,
            shares.resource_id AS resource_id,
            shares.status AS status,
            shares.created_at AS created_at,
            shares.accepted_at AS accepted_at,
            shares.revoked_at AS revoked_at,
            tenants.owner_email AS owner_email
     FROM shares
     LEFT JOIN tenants ON tenants.id = shares.owner_tenant_id
     WHERE (shares.recipient_tenant_id = ? OR lower(shares.recipient_email) = ?)
       AND shares.status IN ('pending', 'accepted')
     ORDER BY shares.created_at DESC`,
  )
    .bind(auth.tenantId, ownerEmail)
    .all<ShareRow & { owner_email: string | null }>();

  return json({
    shares: rows.results.map((r) =>
      rowToRecord(r, { ownerEmail: r.owner_email ?? undefined }),
    ),
  });
}

export async function acceptShare(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
): Promise<Response> {
  if (!isSharingEnabled(env)) return sharingDisabledResponse();
  const ownerEmail = await tenantOwnerEmail(env, auth.tenantId);
  if (!ownerEmail) return badRequest("set an account email before accepting shares");

  const share = await getShare(env, id);
  if (!share) return notFound();
  if (share.status !== "pending") {
    return badRequest(`cannot accept share in state '${share.status}'`);
  }

  const matchesByTenant = share.recipient_tenant_id === auth.tenantId;
  const matchesByEmail = normalizeEmail(share.recipient_email) === ownerEmail;
  if (!matchesByTenant && !matchesByEmail) {
    return notFound();
  }

  const now = new Date().toISOString();
  await env.ZW_DB.prepare(
    `UPDATE shares
     SET status = 'accepted', recipient_tenant_id = ?, accepted_at = ?
     WHERE id = ?`,
  )
    .bind(auth.tenantId, now, id)
    .run();

  const updated = await getShare(env, id);
  return json({ share: updated ? rowToRecord(updated) : null });
}

export async function declineShare(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
): Promise<Response> {
  if (!isSharingEnabled(env)) return sharingDisabledResponse();
  const ownerEmail = await tenantOwnerEmail(env, auth.tenantId);
  if (!ownerEmail) return badRequest("set an account email before declining shares");

  const share = await getShare(env, id);
  if (!share) return notFound();

  const matchesByTenant = share.recipient_tenant_id === auth.tenantId;
  const matchesByEmail = normalizeEmail(share.recipient_email) === ownerEmail;
  if (!matchesByTenant && !matchesByEmail) return notFound();

  await env.ZW_DB.prepare(
    `UPDATE shares SET status = 'declined' WHERE id = ?`,
  )
    .bind(id)
    .run();
  return json({ ok: true });
}

export async function revokeShare(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
): Promise<Response> {
  if (!isSharingEnabled(env)) return sharingDisabledResponse();
  const share = await getShare(env, id);
  if (!share) return notFound();
  // Either side can revoke their relationship to the share.
  const isOwner = share.owner_tenant_id === auth.tenantId;
  const isRecipient = share.recipient_tenant_id === auth.tenantId;
  if (!isOwner && !isRecipient) return notFound();

  const now = new Date().toISOString();
  await env.ZW_DB.prepare(
    `UPDATE shares SET status = 'revoked', revoked_at = ? WHERE id = ?`,
  )
    .bind(now, id)
    .run();
  return json({ ok: true });
}

// ---------- Internal helpers used by cards/activities/push fanout ----------

/// Returns the accepted shares whose owner is `ownerTenantId` and that match
/// the given resource. Used for push fanout.
export async function listAcceptedShares(
  env: Env,
  ownerTenantId: string,
  resourceKind: ShareResourceKind,
  resourceId: string,
): Promise<ShareRecord[]> {
  if (!isSharingEnabled(env)) return [];
  const rows = await env.ZW_DB.prepare(
    `SELECT id, owner_tenant_id, recipient_tenant_id, recipient_email,
            resource_kind, resource_id, status, created_at, accepted_at, revoked_at
     FROM shares
     WHERE owner_tenant_id = ?
       AND resource_kind = ?
       AND resource_id = ?
       AND status = 'accepted'
       AND recipient_tenant_id IS NOT NULL`,
  )
    .bind(ownerTenantId, resourceKind, resourceId)
    .all<ShareRow>();
  return rows.results.map((r) => rowToRecord(r));
}

/// Returns the accepted shares incoming for `recipientTenantId` of the given
/// kind. Used to expand `?include=shared` on GET endpoints.
export async function listAcceptedIncomingByKind(
  env: Env,
  recipientTenantId: string,
  resourceKind: ShareResourceKind,
): Promise<Array<ShareRecord & { ownerEmail: string }>> {
  if (!isSharingEnabled(env)) return [];
  const rows = await env.ZW_DB.prepare(
    `SELECT shares.id AS id,
            shares.owner_tenant_id AS owner_tenant_id,
            shares.recipient_tenant_id AS recipient_tenant_id,
            shares.recipient_email AS recipient_email,
            shares.resource_kind AS resource_kind,
            shares.resource_id AS resource_id,
            shares.status AS status,
            shares.created_at AS created_at,
            shares.accepted_at AS accepted_at,
            shares.revoked_at AS revoked_at,
            tenants.owner_email AS owner_email
     FROM shares
     JOIN tenants ON tenants.id = shares.owner_tenant_id
     WHERE shares.recipient_tenant_id = ?
       AND shares.resource_kind = ?
       AND shares.status = 'accepted'`,
  )
    .bind(recipientTenantId, resourceKind)
    .all<ShareRow & { owner_email: string }>();
  return rows.results.map((r) => ({
    ...rowToRecord(r, { ownerEmail: r.owner_email }),
    ownerEmail: r.owner_email,
  }));
}

/// Cleanup hook called when an owner deletes a card.
export async function revokeSharesForCard(
  env: Env,
  ownerTenantId: string,
  cardId: string,
): Promise<void> {
  const now = new Date().toISOString();
  await env.ZW_DB.prepare(
    `UPDATE shares
     SET status = 'revoked', revoked_at = ?
     WHERE owner_tenant_id = ?
       AND resource_kind = 'card'
       AND resource_id = ?
       AND status IN ('pending', 'accepted')`,
  )
    .bind(now, ownerTenantId, cardId)
    .run();
}
