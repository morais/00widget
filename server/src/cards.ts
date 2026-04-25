import type { Env } from "./types";
import { DashboardCardSchema } from "./types";
import * as storage from "./storage";
import { sendWidgetReloadPush } from "./apns";
import { json, badRequest } from "./http";
import type { AuthContext } from "./auth";

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
  await storage.putCard(env, auth.apiKeyHash, card);

  // Fan out a WidgetKit reload push to every registered widget token.
  // Failures are logged but not surfaced to the caller.
  const tokens = await storage.listWidgetTokens(env, auth.apiKeyHash);
  for (const token of tokens) {
    const result = await sendWidgetReloadPush(env, token);
    if (result.status !== 200 && result.status !== 0) {
      console.log("widget push failed", { status: result.status, reason: result.reason });
    }
  }

  return json({ card }, 200);
}

export async function listCards(_req: Request, env: Env, auth: AuthContext): Promise<Response> {
  const cards = await storage.listCards(env, auth.apiKeyHash);
  return json({ cards }, 200);
}

export async function getCard(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
): Promise<Response> {
  const card = await storage.getCard(env, auth.apiKeyHash, id);
  if (!card) return json({ error: "not found" }, 404);
  return json(card, 200);
}

export async function deleteCard(
  _req: Request,
  env: Env,
  auth: AuthContext,
  id: string,
): Promise<Response> {
  await storage.deleteCard(env, auth.apiKeyHash, id);
  return json({ ok: true }, 200);
}

export async function parseJson(req: Request): Promise<unknown> {
  try {
    return await req.json();
  } catch {
    return null;
  }
}
