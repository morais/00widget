import type { AuthContext } from "./auth";
import { json } from "./http";
import * as storage from "./storage";
import type { Env } from "./types";
import { listActiveActivitySessions } from "./liveActivities";

export async function getDashboard(
  _req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const [cards, activities] = await Promise.all([
    storage.listCards(env, auth.tenantId),
    listActiveActivitySessions(env, auth.tenantId),
  ]);
  return json({ cards, activities });
}
