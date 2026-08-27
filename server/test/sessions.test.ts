import { describe, expect, it } from "vitest";
import handler from "../src/index";
import { ApiScopePresets, createApiKey, listApiKeys } from "../src/auth";
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
      scopes: ApiScopePresets.device,
    });
    const app = await createApiKey(env, {
      tenantId: "test-tenant",
      label: "iPhone (app only)",
      kind: "app",
      sessionId,
      deviceId,
      scopes: ApiScopePresets.appOnly,
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

  it("leaves account-level Agent-config tokens active when a device signs out", async () => {
    const env = makeEnv();
    const sessionId = "device-session";
    const device = await createApiKey(env, {
      tenantId: "test-tenant",
      purpose: "device",
      sessionId,
      deviceId: "iphone-agent-survives",
      scopes: ApiScopePresets.device,
    });
    const app = await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "app",
      purpose: "app",
      sessionId,
      deviceId: "iphone-agent-survives",
      scopes: ApiScopePresets.appOnly,
    });
    const agent = await createApiKey(env, {
      tenantId: "test-tenant",
      purpose: "agent",
      scopes: ApiScopePresets.producer,
    });

    const signOut = await (handler.fetch as any)(
      authedRequest("https://x/v1/auth/token", { method: "DELETE" }, app.token),
      env,
      executionCtx,
    );
    expect(signOut.status).toBe(200);

    for (const signedOut of [app.token, device.token]) {
      const after = await (handler.fetch as any)(
        authedRequest("https://x/v1/cards", {}, signedOut),
        env,
        executionCtx,
      );
      expect(after.status).toBe(401);
    }
    const agentAfter = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", {}, agent.token),
      env,
      executionCtx,
    );
    expect(agentAfter.status).toBe(200);
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
      scopes: ApiScopePresets.device,
    });
    await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "app",
      sessionId: "admin-revoked-session",
      deviceId: "iphone-admin",
      scopes: ApiScopePresets.appOnly,
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

describe("agent token rotation", () => {
  it("atomically replaces Agent-config tokens without touching devices, links, or connectors", async () => {
    const env = makeEnv();
    const tenantId = "test-tenant";
    const sessionId = "iphone-session";
    const deviceId = "iphone-rotate";
    const device = await createApiKey(env, {
      tenantId,
      kind: "publisher",
      purpose: "device",
      sessionId,
      deviceId,
      scopes: ApiScopePresets.device,
    });
    const app = await createApiKey(env, {
      tenantId,
      kind: "app",
      purpose: "app",
      sessionId,
      deviceId,
      scopes: ApiScopePresets.appOnly,
    });
    const firstAgent = await createApiKey(env, {
      tenantId,
      purpose: "agent",
      scopes: ApiScopePresets.producer,
    });
    const secondAgent = await createApiKey(env, {
      tenantId,
      purpose: "agent",
      scopes: ApiScopePresets.producer,
    });
    const connector = await createApiKey(env, {
      tenantId,
      purpose: "connector",
      scopes: ApiScopePresets.mcp,
    });
    const guest = await createApiKey(env, {
      tenantId,
      kind: "guest",
      purpose: "guest",
      scopes: ApiScopePresets.guest,
      resourceKind: "card",
      resourceId: "shared-card",
    });

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/auth/agent-token/rotate", { method: "POST" }, app.token),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);
    const body = await response.json() as {
      ok: boolean;
      token: string;
      revokedAgentTokens: number;
    };
    expect(body.ok).toBe(true);
    expect(body.token).toMatch(/^zw_/);
    expect(body.revokedAgentTokens).toBe(2);

    for (const oldAgent of [firstAgent.token, secondAgent.token]) {
      const after = await (handler.fetch as any)(
        authedRequest("https://x/v1/cards", {}, oldAgent),
        env,
        executionCtx,
      );
      expect(after.status).toBe(401);
    }
    for (const surviving of [device.token, app.token, connector.token]) {
      const after = await (handler.fetch as any)(
        authedRequest(
          surviving === app.token ? "https://x/v1/account" : "https://x/v1/cards",
          {},
          surviving,
        ),
        env,
        executionCtx,
      );
      expect(after.status).toBe(200);
    }
    const guestAfter = await (handler.fetch as any)(
      authedRequest("https://x/v1/guest/resource", {}, guest.token),
      env,
      executionCtx,
    );
    // The missing bound card is unrelated to authentication: anything but a
    // 401 proves rotation did not revoke the guest credential.
    expect(guestAfter.status).not.toBe(401);

    const replacement = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", {}, body.token),
      env,
      executionCtx,
    );
    expect(replacement.status).toBe(200);
  });

  it("requires the app-only credential", async () => {
    const env = makeEnv();
    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/auth/agent-token/rotate", { method: "POST" }),
      env,
      executionCtx,
    );
    expect(response.status).toBe(403);
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
