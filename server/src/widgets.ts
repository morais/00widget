import type { Env } from "./types";
import { RegisterWidgetPushTokenSchema, RequestBodyLimits } from "./types";
import * as storage from "./storage";
import { json, badRequest } from "./http";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";
import { enforceTenantRateLimits, tenantKey } from "./rateLimit";

export async function registerWidgetPushToken(
  req: Request,
  env: Env,
  auth: AuthContext,
): Promise<Response> {
  const body = await parseJson(req, RequestBodyLimits.registration);
  const parsed = RegisterWidgetPushTokenSchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const limited = await enforceTenantRateLimits(env, auth, [
    { policy: "registrationTenantDay", key: tenantKey(auth.tenantId) },
  ]);
  if (limited) return limited;
  const { deviceId, widgetKind, widgetPushToken } = parsed.data;
  await storage.putWidgetToken(
    env,
    auth.tenantId,
    auth.apiKeyHash,
    deviceId,
    widgetKind,
    widgetPushToken,
  );
  return json({ ok: true });
}
