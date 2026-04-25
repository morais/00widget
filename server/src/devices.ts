import type { Env } from "./types";
import { RegisterDeviceSchema } from "./types";
import * as storage from "./storage";
import { json, badRequest } from "./http";
import type { AuthContext } from "./auth";
import { parseJson } from "./cards";

export async function registerDevice(req: Request, env: Env, auth: AuthContext): Promise<Response> {
  const body = await parseJson(req);
  const parsed = RegisterDeviceSchema.safeParse(body);
  if (!parsed.success) return badRequest(`validation failed: ${parsed.error.message}`);
  const { deviceId, apnsDeviceToken, appVersion, platform } = parsed.data;
  await storage.putDevice(env, auth.apiKeyHash, deviceId, {
    apnsDeviceToken,
    appVersion,
    platform,
    updatedAt: new Date().toISOString(),
  });
  return json({ ok: true });
}
