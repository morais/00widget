import type { Env } from "./types";
import { RegisterWidgetPushTokenSchema } from "./types";
import * as storage from "./storage";
import { json, badRequest } from "./http";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";

export async function registerWidgetPushToken(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req);
  const parsed = RegisterWidgetPushTokenSchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const { deviceId, widgetKind, widgetPushToken } = parsed.data;
  await storage.putWidgetToken(env, auth.apiKeyHash, deviceId, widgetKind, widgetPushToken);
  return json({ ok: true });
}
