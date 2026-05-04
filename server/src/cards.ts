import type { Env } from "./types";
import { DashboardCardSchema, type DashboardCard } from "./types";
import * as storage from "./storage";
import { sendWidgetReloadPush } from "./apns";
import { json, badRequest } from "./http";
import type { AuthContext } from "./auth";
import {
  isSharingEnabled,
  listAcceptedIncomingByKind,
  listAcceptedShares,
  revokeSharesForCard,
} from "./shares";

export async function upsertCard(req: Request, env: Env, auth: AuthContext): Promise<Response> {
  const body = await parseJson(req);
  if (!body) return badRequest("invalid JSON body");
  const parsed = DashboardCardSchema.safeParse(body);
  if (!parsed.success) {
    return badRequest(`validation failed: ${parsed.error.message}`);
  }
  const card = {
    ...parsed.data,
    updatedAt: parsed.data.updatedAt ?? new Date().toISOString(),
  };
  await storage.putCard(env, auth.tenantId, auth.apiKeyHash, card);

  // Fan out a WidgetKit reload push to the owner's widgets, plus any
  // accepted-share recipients' widgets that render this card kind.
  const widgetKind = widgetKindForCard(card);
  const tokens = await collectWidgetTokensForCard(env, auth.tenantId, card.id, widgetKind);
  for (const token of tokens) {
    const result = await sendWidgetReloadPush(env, token);
    if (result.status !== 200 && result.status !== 0) {
      console.log("widget push failed", { status: result.status, reason: result.reason });
    }
  }

  return json({ card }, 200);
}

async function collectWidgetTokensForCard(
  env: Env,
  ownerTenantId: string,
  cardId: string,
  widgetKind: string,
): Promise<string[]> {
  const tokens = await storage.listWidgetTokensForKind(env, ownerTenantId, widgetKind);
  if (!isSharingEnabled(env)) return tokens;
  const accepted = await listAcceptedShares(env, ownerTenantId, "card", cardId);
  for (const share of accepted) {
    if (!share.recipientTenantId) continue;
    const recipientTokens = await storage.listWidgetTokensForKind(
      env,
      share.recipientTenantId,
      widgetKind,
    );
    tokens.push(...recipientTokens);
  }
  return tokens;
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
  return json(card, 200);
}

export async function deleteCard(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
): Promise<Response> {
  await storage.deleteCard(env, auth.tenantId, id);
  await revokeSharesForCard(env, auth.tenantId, id);
  return json({ ok: true }, 200);
}

export async function parseJson(req: Request): Promise<unknown> {
  try {
    return await req.json();
  } catch {
    return null;
  }
}

function widgetKindForCard(card: DashboardCard): string {
  switch (card.template) {
    case "status":
      return "ZeroZeroWidgetStatusWidget";
    case "progress":
      return "ZeroZeroWidgetProgressWidget";
    case "list":
      return "ZeroZeroWidgetListWidget";
    case "metric":
    case "timer":
    case "action":
      return "ZeroZeroWidgetMetricWidget";
  }
}
