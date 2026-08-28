import { describe, expect, it } from "vitest";
import handler from "../src/index";
import {
  ApiScopePresets,
  createApiKey,
  revokeApiKey,
} from "../src/auth";
import { authedRequest, makeEnv } from "./helpers";

const executionCtx = {} as ExecutionContext;

describe("MCP connection management", () => {
  it("lists only this account's active connectors without exposing credentials or the approver", async () => {
    const env = makeEnv();
    const app = await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "app",
      purpose: "app",
      scopes: ApiScopePresets.appOnly,
    });
    const connector = await createApiKey(env, {
      tenantId: "test-tenant",
      label: "MCP · ChatGPT · owner@example.com",
      purpose: "connector",
      scopes: ApiScopePresets.mcp,
    });
    const revoked = await createApiKey(env, {
      tenantId: "test-tenant",
      label: "MCP · Old Claude · owner@example.com",
      purpose: "connector",
      scopes: ApiScopePresets.mcp,
    });
    await revokeApiKey(env, revoked.apiKey.id);
    await createApiKey(env, {
      tenantId: "test-tenant",
      label: "Agent config",
      purpose: "agent",
      scopes: ApiScopePresets.producer,
    });
    await createApiKey(env, {
      tenantId: "other-tenant",
      ownerEmail: "other@example.com",
      label: "MCP · Claude · other@example.com",
      purpose: "connector",
      scopes: ApiScopePresets.mcp,
    });

    const response = await (handler.fetch as any)(
      authedRequest("https://x/v1/account/mcp-connections", {}, app.token),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);
    const body = await response.json() as any;
    expect(body.connections).toEqual([
      expect.objectContaining({
        id: connector.apiKey.id,
        clientName: "ChatGPT",
        scopes: ["read", "publish"],
      }),
    ]);
    expect(JSON.stringify(body)).not.toContain(connector.token);
    expect(JSON.stringify(body)).not.toContain(connector.apiKey.tokenHash);
    expect(JSON.stringify(body)).not.toContain("owner@example.com");
  });

  it("disconnects one connector without touching another credential", async () => {
    const env = makeEnv();
    const app = await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "app",
      purpose: "app",
      scopes: ApiScopePresets.appOnly,
    });
    const connector = await createApiKey(env, {
      tenantId: "test-tenant",
      purpose: "connector",
      scopes: ApiScopePresets.mcp,
    });
    const agent = await createApiKey(env, {
      tenantId: "test-tenant",
      purpose: "agent",
      scopes: ApiScopePresets.producer,
    });

    const response = await (handler.fetch as any)(
      authedRequest(
        `https://x/v1/account/mcp-connections/${connector.apiKey.id}`,
        { method: "DELETE" },
        app.token,
      ),
      env,
      executionCtx,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, revoked: true });

    const connectorAfter = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", {}, connector.token),
      env,
      executionCtx,
    );
    expect(connectorAfter.status).toBe(401);
    const agentAfter = await (handler.fetch as any)(
      authedRequest("https://x/v1/cards", {}, agent.token),
      env,
      executionCtx,
    );
    expect(agentAfter.status).toBe(200);
  });

  it("cannot disconnect another tenant's connector or a non-connector credential", async () => {
    const env = makeEnv();
    const app = await createApiKey(env, {
      tenantId: "test-tenant",
      kind: "app",
      purpose: "app",
      scopes: ApiScopePresets.appOnly,
    });
    const other = await createApiKey(env, {
      tenantId: "other-tenant",
      ownerEmail: "other@example.com",
      purpose: "connector",
      scopes: ApiScopePresets.mcp,
    });
    const agent = await createApiKey(env, {
      tenantId: "test-tenant",
      purpose: "agent",
      scopes: ApiScopePresets.producer,
    });

    for (const id of [other.apiKey.id, agent.apiKey.id]) {
      const response = await (handler.fetch as any)(
        authedRequest(
          `https://x/v1/account/mcp-connections/${id}`,
          { method: "DELETE" },
          app.token,
        ),
        env,
        executionCtx,
      );
      expect(response.status).toBe(404);
    }
  });

  it("requires the app-only credential for listing and disconnecting", async () => {
    const env = makeEnv();
    const connector = await createApiKey(env, {
      tenantId: "test-tenant",
      purpose: "connector",
      scopes: ApiScopePresets.mcp,
    });

    for (const [method, path] of [
      ["GET", "/v1/account/mcp-connections"],
      ["DELETE", `/v1/account/mcp-connections/${connector.apiKey.id}`],
    ]) {
      const response = await (handler.fetch as any)(
        authedRequest(`https://x${path}`, { method }, connector.token),
        env,
        executionCtx,
      );
      expect(response.status).toBe(403);
    }
  });
});
