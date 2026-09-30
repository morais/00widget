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
  return json(await loadDashboard(env, auth.tenantId));
}

/// Shared with the signed-in web page, which resolves the tenant from a
/// session rather than from a bearer credential.
export async function loadDashboard(env: Env, tenantId: string) {
  const [cards, activities] = await Promise.all([
    storage.listCards(env, tenantId),
    listActiveActivitySessions(env, tenantId),
  ]);
  return { cards, activities };
}
