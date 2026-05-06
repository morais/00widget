import type { Env } from "./types";
import { DashboardCardSchema, RequestBodyLimits, type DashboardCard } from "./types";
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
  const body = await parseJson(req, RequestBodyLimits.card);
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

  // Fan out a WidgetKit reload push to the owner's card/grid widgets, plus
  // accepted-share recipients' card/grid widgets.
  const tokens = await collectWidgetTokensForCard(env, auth.tenantId, card.id);
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
): Promise<string[]> {
  const tokens = await listCardWidgetTokens(env, ownerTenantId);
  if (!isSharingEnabled(env)) return tokens;
  const accepted = await listAcceptedShares(env, ownerTenantId, "card", cardId);
  for (const share of accepted) {
    if (!share.recipientTenantId) continue;
    const recipientTokens = await listCardWidgetTokens(env, share.recipientTenantId);
    tokens.push(...recipientTokens);
  }
  return [...new Set(tokens)];
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

async function listCardWidgetTokens(env: Env, tenantId: string): Promise<string[]> {
  const widgetKinds = ["ZeroZeroWidgetCardWidget", "ZeroZeroWidgetCardGridWidget"];
  const nested = await Promise.all(
    widgetKinds.map((kind) => storage.listWidgetTokensForKind(env, tenantId, kind)),
  );
  return nested.flat();
}
