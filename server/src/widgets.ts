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
  if ("subscriptions" in parsed.data) {
    await storage.replaceWidgetTokensForDevice(
      env,
      auth.tenantId,
      auth.apiKeyHash,
      parsed.data.deviceId,
      parsed.data.widgetPushToken,
      parsed.data.subscriptions,
      {
        appVersion: parsed.data.appVersion,
        platform: parsed.data.platform,
      },
    );
    console.log("widget registration synced", {
      event: "widget.registration.synced",
      tenantId: auth.tenantId,
      devicePrefix: parsed.data.deviceId.slice(0, 8),
      appVersion: parsed.data.appVersion,
      platform: parsed.data.platform,
      tokenPresent: Boolean(parsed.data.widgetPushToken),
      subscriptionCount: parsed.data.subscriptions.length,
      widgetKinds: [...new Set(parsed.data.subscriptions.map((item) => item.widgetKind))],
    });
  } else {
    const { deviceId, widgetKind, widgetPushToken } = parsed.data;
    await storage.putWidgetToken(
      env,
      auth.tenantId,
      auth.apiKeyHash,
      deviceId,
      widgetKind,
      widgetPushToken,
    );
    console.log("legacy widget registration synced", {
      event: "widget.registration.legacy",
      tenantId: auth.tenantId,
      devicePrefix: deviceId.slice(0, 8),
      widgetKind,
    });
  }
  return json({ ok: true });
}
