import { describe, expect, it } from "vitest";
import handler from "../src/index";
import { createApiKey, listApiKeys } from "../src/auth";
import * as storage from "../src/storage";
import { revokeCredentialById } from "../src/sessions";
import { authedRequest, makeEnv, seedApiKey } from "./helpers";

const executionCtx = {} as ExecutionContext;

describe("credential revocation", () => {
  it("revokes an Apple app session and removes every device registration", async () => {
    const env = makeEnv();
    const sessionId = "session-1";
    const deviceId = "iphone-1";
    const publisher = await createApiKey(env, {
      tenantId: "test-tenant",
      label: "iPhone",
      kind: "publisher",
      sessionId,
      deviceId,
    });
    const app = await createApiKey(env, {
      tenantId: "test-tenant",
      label: "iPhone (app only)",
      kind: "app",
      sessionId,
      deviceId,
    });

    await registerAllDeviceTokens(env, publisher.token, deviceId);

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/auth/token", { method: "DELETE" }, app.token),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      ok: true,
      revokedCredentials: 2,
      removedRegistrations: 4,
    });

    const sessionKeys = (await listApiKeys(env)).filter((key) => key.sessionId === sessionId);
    expect(sessionKeys).toHaveLength(2);
    expect(sessionKeys.every((key) => Boolean(key.revokedAt))).toBe(true);
    await expect(storage.listTenantDevices(env, "test-tenant")).resolves.toEqual([]);
    await expect(storage.listTenantWidgetTokens(env, "test-tenant")).resolves.toEqual([]);
    await expect(storage.listTenantActivities(env, "test-tenant")).resolves.toEqual([]);
    await expect(storage.listTenantStartTokens(env, "test-tenant")).resolves.toEqual([]);
  });

  it("lets a standalone publisher token revoke itself", async () => {
    const env = makeEnv();
    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/auth/token", { method: "DELETE" }),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);

    const after = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards"),
      env,
      executionCtx,
    );
    expect(after.status).toBe(401);
  });

  it("revokes both halves when a paired publisher credential initiates cleanup", async () => {
    const env = makeEnv();
    const publisher = await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "publisher",
      sessionId: "session-publisher-revoke",
      deviceId: "iphone-2",
    });
    await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "app",
      sessionId: "session-publisher-revoke",
      deviceId: "iphone-2",
    });

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/auth/token", { method: "DELETE" }, publisher.token),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ revokedCredentials: 2 });
  });

  it("allows an expired credential to revoke itself and clean up", async () => {
    const env = makeEnv();
    await seedApiKey(
      env,
      "expired-key",
      "test-tenant",
      "publisher",
      "",
      "expired-device",
      "2020-01-01T00:00:00.000Z",
    );
    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/auth/token", { method: "DELETE" }, "expired-key"),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);
  });

  it("uses the same session cleanup when an administrator revokes a key", async () => {
    const env = makeEnv();
    const publisher = await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "publisher",
      sessionId: "admin-revoked-session",
      deviceId: "iphone-admin",
    });
    await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "app",
      sessionId: "admin-revoked-session",
      deviceId: "iphone-admin",
    });
    await registerAllDeviceTokens(env, publisher.token, "iphone-admin");

    await expect(revokeCredentialById(env, publisher.apiKey.id)).resolves.toBe(true);
    expect(
      (await listApiKeys(env))
        .filter((key) => key.sessionId === "admin-revoked-session")
        .every((key) => Boolean(key.revokedAt)),
    ).toBe(true);
    await expect(storage.listTenantDevices(env, "test-tenant")).resolves.toEqual([]);
    await expect(storage.listTenantWidgetTokens(env, "test-tenant")).resolves.toEqual([]);
    await expect(storage.listTenantActivities(env, "test-tenant")).resolves.toEqual([]);
    await expect(storage.listTenantStartTokens(env, "test-tenant")).resolves.toEqual([]);
  });
});

async function registerAllDeviceTokens(
  env: ReturnType<typeof makeEnv>,
  token: string,
  deviceId: string,
): Promise<void> {
  const requests = [
    ["/v1/devices/register", {
      deviceId,
      apnsDeviceToken: "aabbccdd",
      appVersion: "1.0",
      platform: "ios",
    }],
    ["/v1/widgets/register-push-token", {
      deviceId,
      widgetKind: "ZeroZeroWidgetCardWidget",
      widgetPushToken: "bbccddee",
    }],
    ["/v1/live-activities/register-start-token", {
      deviceId,
      attributesType: "ZeroZeroWidgetActivityAttributes",
      pushToken: "ccddeeaa",
    }],
    ["/v1/live-activities/register", {
      deviceId,
      localActivityId: "local-1",
      externalActivityId: "activity-1",
      kind: "job",
      pushToken: "ddeeaabb",
    }],
  ] as const;

  for (const [path, body] of requests) {
    const response = await (handler.fetch as any)(
      authedRequest(`https://x${path}`, {
        method: "POST",
        body: JSON.stringify(body),
      }, token),
      env,
      executionCtx,
    );
    expect(response.status, path).toBe(200);
  }
}
