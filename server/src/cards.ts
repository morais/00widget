import type { Env } from "./types";
import {
  BatchUpsertCardsSchema,
  DashboardCardInputSchema,
  RequestBodyLimits,
  type DashboardCard,
} from "./types";
import * as storage from "./storage";
import { json, badRequest } from "./http";
import type { AuthContext } from "./auth";
import {
  isSharingEnabled,
  listAcceptedIncomingByKind,
  revokeSharesForCard,
} from "./shares";
import {
  enforceRateLimits,
  enforceTenantRateLimits,
  tenantKey,
  tenantResourceKey,
} from "./rateLimit";
import {
  collectWidgetPushTargetsForCard,
  scheduleWidgetReloadForCard,
  scheduleWidgetReloadForCards,
  scheduleWidgetReloads,
} from "./widgetPush";

export async function upsertCard(
  req: Request,
  env: Env,
  auth: AuthContext,
  ctx: ExecutionContext,
): Promise<Response> {
  const body = await parseJson(req, RequestBodyLimits.card);
  if (!body) return badRequest("invalid JSON body");
  const parsed = DashboardCardInputSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(`validation failed: ${parsed.error.message}`);
  }
  const limited = await enforceTenantRateLimits(env, auth, [
    { policy: "cardUpsertTenantHour", key: tenantKey(auth.tenantId) },
    { policy: "cardUpsertCardHour", key: tenantResourceKey(auth.tenantId, "card", parsed.data.id) },
  ]);
  if (limited) return limited;
  const inputCard = {
    ...parsed.data,
    updatedAt: parsed.data.updatedAt ?? new Date().toISOString(),
  };
  const card = await storage.putCard(env, auth.tenantId, auth.apiKeyHash, inputCard);

  scheduleWidgetReloadForCard(ctx, env, auth.tenantId, card.id);

  return json({ card }, 200);
}

export async function upsertCardsBatch(
  req: Request,
  env: Env,
  auth: AuthContext,
  ctx: ExecutionContext,
): Promise<Response> {
  const body = await parseJson(req, RequestBodyLimits.cardBatch);
  if (!body) return badRequest("invalid JSON body");
  const parsed = BatchUpsertCardsSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(`validation failed: ${parsed.error.message}`);
  }
  const limited = await enforceRateLimits(env, [
    { policy: "anyWriteTenantHour", key: tenantKey(auth.tenantId) },
    ...parsed.data.cards.map(() => ({
      policy: "cardUpsertTenantHour" as const,
      key: tenantKey(auth.tenantId),
    })),
    ...parsed.data.cards.map((card) => ({
      policy: "cardUpsertCardHour" as const,
      key: tenantResourceKey(auth.tenantId, "card", card.id),
    })),
  ]);
  if (limited) return limited;

  const receivedAt = new Date().toISOString();
  const inputCards = parsed.data.cards.map((card) => ({
    ...card,
    updatedAt: card.updatedAt ?? receivedAt,
  }));
  const cards = await storage.putCards(env, auth.tenantId, auth.apiKeyHash, inputCards);
  scheduleWidgetReloadForCards(
    ctx,
    env,
    auth.tenantId,
    cards.map((card) => card.id),
  );
  return json({ cards }, 200);
}

export async function listCards(req: Request, env: Env, auth: AuthContext): Promise<Response> {
  const own = await storage.listCards(env, auth.tenantId);
  const url = new URL(req.url);
  const includeShared =
    url.searchParams.get("include") === "shared" && isSharingEnabled(env);
  if (!includeShared) return json({ cards: own }, 200);

  const incoming = await listAcceptedIncomingByKind(env, auth.tenantId, "card");
  const shared: DashboardCard[] = [];
  for (const share of incoming) {
    const card = await storage.getCard(env, share.ownerTenantId, share.resourceId);
    if (!card) continue;
    shared.push({
      ...card,
      sharedBy: { ownerEmail: share.ownerEmail, shareId: share.id },
    });
  }
  return json({ cards: own, shared }, 200);
}

export async function getCard(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
): Promise<Response> {
  const card = await storage.getCard(env, auth.tenantId, id);
  if (!card) return json({ error: "not found" }, 404);
  // `{ card }`, not the bare object. Every other read on this API answers with
  // a single-key envelope, and the argument the Live Activity list makes for it
  // — there is no shape to fall back to and nothing to parse defensively — is
  // not weaker for one card than for a list of them.
  return json({ card }, 200);
}

export async function deleteCard(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
  ctx: ExecutionContext,
): Promise<Response> {
  const limited = await enforceTenantRateLimits(env, auth, []);
  if (limited) return limited;
  await deleteCardForTenant(env, auth.tenantId, id, ctx);
  return json({ ok: true }, 200);
}

export async function deleteCardForTenant(
  env: Env,
  tenantId: string,
  id: string,
  ctx: ExecutionContext,
): Promise<void> {
  // Capture recipients before deleting the card and revoking its shares; the
  // accepted-share relationship is what lets us find every affected device.
  const targets = await collectWidgetPushTargetsForCard(env, tenantId, id);
  await storage.deleteCard(env, tenantId, id);
  await revokeSharesForCard(env, tenantId, id);
  scheduleWidgetReloads(ctx, env, targets, { tenantId, cardId: id });
}

export class RequestBodyTooLargeError extends Error {
  constructor(readonly limitBytes: number) {
    super(`request body exceeds ${limitBytes} bytes`);
    this.name = "RequestBodyTooLargeError";
  }
}

export async function parseJson(req: Request, maxBytes?: number): Promise<unknown> {
  try {
    if (maxBytes === undefined) return await req.json();
    const text = await readTextUpTo(req, maxBytes);
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function readTextUpTo(req: Request, maxBytes: number): Promise<string> {
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done || !value) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new RequestBodyTooLargeError(maxBytes);
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(body);
}
