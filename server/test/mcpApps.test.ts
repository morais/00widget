import { describe, expect, it } from "vitest";
import { sha256Hex } from "../src/auth";
import handler from "../src/index";
import {
  MCP_APP_RESOURCE_URIS,
  MCP_PREVIEW_LEGACY_RESOURCE_URIS,
} from "../src/mcpApp";
import type { Env } from "../src/types";
import { authedRequest, makeEnv, seedApiKey, TEST_API_KEY } from "./helpers";

const ctx = {} as ExecutionContext;
const SESSION_SECRET = "test-session-secret-0123456789abcdef";

function fetchWorker(req: Request, env: Env): Promise<Response> {
  return (handler.fetch as (r: Request, e: Env, c: ExecutionContext) => Promise<Response>)(
    req,
    env,
    ctx,
  );
}

function env(overrides: Partial<Env> = {}): Env {
  return makeEnv({
    MCP_ENABLED: "true",
    MCP_PREVIEW_ENABLED: "true",
    SESSION_SECRET,
    ...overrides,
  });
}

async function rpc(
  currentEnv: Env,
  path: "/mcp" | "/mcp-preview",
  body: unknown,
  authenticated = true,
): Promise<Response> {
  const init: RequestInit = {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
  const url = `https://api.example.com${path}`;
  const req = authenticated ? authedRequest(url, init, TEST_API_KEY) : new Request(url, init);
  return fetchWorker(req, currentEnv);
}

async function result(
  currentEnv: Env,
  path: "/mcp" | "/mcp-preview",
  method: string,
  params?: unknown,
): Promise<Record<string, any>> {
  const res = await rpc(currentEnv, path, { jsonrpc: "2.0", id: 1, method, params });
  return await res.json() as Record<string, any>;
}

describe("MCP Apps", () => {
  it("is absent until its own switch is enabled", async () => {
    const disabled = env({ MCP_PREVIEW_ENABLED: "false" });
    const post = await rpc(disabled, "/mcp-preview", {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list",
    });
    expect(post.status).toBe(404);

    const get = await fetchWorker(new Request("https://api.example.com/mcp-preview"), disabled);
    expect(get.status).toBe(404);
    const metadata = await fetchWorker(
      new Request("https://api.example.com/.well-known/oauth-protected-resource/mcp-preview"),
      disabled,
    );
    expect(metadata.status).toBe(404);
  });

  it("preserves the ordered pre-promotion stable and preview descriptors", async () => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");

    // Captured from tools/list before promotion, including OAuth metadata.
    const stable = (await result(currentEnv, "/mcp", "tools/list")).result.tools;
    expect(stable).toHaveLength(15);
    expect(await sha256Hex(JSON.stringify(stable.slice(0, 12)))).toBe(
      "54e3aceeb058d491b8d4ec20abf5a61c3e6690cb5c72a25742db96b0d112a3b8",
    );
    const preview = (await result(currentEnv, "/mcp-preview", "tools/list")).result.tools;
    expect(await sha256Hex(JSON.stringify(preview))).toBe(
      "0a3977ed559dc94f3816a0c4cd7a5717fd247b61ccbb8e75c06617403d621bfd",
    );
  });

  it("advertises resources and three additive render tools on /mcp with preview disabled", async () => {
    const currentEnv = env({ MCP_PREVIEW_ENABLED: "false" });
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");

    const stable = await result(currentEnv, "/mcp", "tools/list");
    const tools = stable.result.tools as Array<Record<string, any>>;
    const renderTools = tools.slice(-3);
    expect(renderTools.map((tool) => tool.name)).toEqual([
      "render_card",
      "render_activity",
      "render_dashboard",
    ]);

    for (const tool of renderTools) {
      expect(tool.annotations).toMatchObject({
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      });
      expect(tool.securitySchemes).toEqual([{ type: "oauth2", scopes: ["read"] }]);
      expect(tool._meta.ui).toEqual({
        resourceUri: MCP_APP_RESOURCE_URIS.stable,
        visibility: ["model", "app"],
      });
      expect(tool._meta["ui/resourceUri"]).toBe(MCP_APP_RESOURCE_URIS.stable);
      expect(tool._meta["openai/outputTemplate"]).toBe(MCP_APP_RESOURCE_URIS.stable);
      expect(tool.outputSchema.type).toBe("object");
    }

    const initialized = await result(currentEnv, "/mcp", "initialize", {
      protocolVersion: "2025-06-18",
    });
    expect(initialized.result.capabilities).toEqual({
      tools: { listChanged: false },
      resources: { listChanged: false },
    });
    const discovered = await result(currentEnv, "/mcp", "server/discover");
    expect(discovered.result.capabilities).toEqual({ tools: {}, resources: {} });
  });

  it("serves the versioned self-contained MCP App resource", async () => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");

    const listed = await result(currentEnv, "/mcp", "resources/list");
    expect(listed.result.resources).toEqual([
      expect.objectContaining({
        uri: MCP_APP_RESOURCE_URIS.stable,
        mimeType: "text/html;profile=mcp-app",
        _meta: {
          ui: {
            prefersBorder: false,
            csp: { connectDomains: [], resourceDomains: [] },
          },
        },
      }),
    ]);

    const read = await result(currentEnv, "/mcp", "resources/read", {
      uri: MCP_APP_RESOURCE_URIS.stable,
    });
    const resource = read.result.contents[0];
    expect(resource.uri).toBe(MCP_APP_RESOURCE_URIS.stable);
    expect(resource.mimeType).toBe("text/html;profile=mcp-app");
    expect(resource._meta.ui).toEqual({
      prefersBorder: false,
      csp: { connectDomains: [], resourceDomains: [] },
    });
    expect(resource._meta.ui).not.toHaveProperty("domain");
    expect(resource._meta["openai/widgetDomain"]).toBe("https://api.example.com");
    expect(resource._meta["openai/ui"].availableDisplayModes).toEqual(["inline", "fullscreen"]);
    expect(resource.text).toContain("ZeroZeroPreview");
    expect(resource.text).toContain("ui/initialize");
    expect(resource.text).toContain("ui/notifications/tool-result");
    expect(resource.text).toContain("tools/call");
    expect(resource.text).toContain("availableDisplayModes:['inline','fullscreen']");
    expect(resource.text).not.toMatch(/<script[^>]+src=/);
    const scripts = [...String(resource.text).matchAll(/<script>([\s\S]*?)<\/script>/g)]
      .map((match) => match[1]);
    expect(scripts).toHaveLength(2);
    for (const script of scripts) expect(() => new Function(script)).not.toThrow();

    const previewResources = await result(currentEnv, "/mcp-preview", "resources/list");
    expect(previewResources.result.resources.map(({ uri }: { uri: string }) => uri)).toEqual([
      MCP_APP_RESOURCE_URIS.preview,
    ]);
    for (const uri of [MCP_APP_RESOURCE_URIS.preview, ...MCP_PREVIEW_LEGACY_RESOURCE_URIS]) {
      const preview = await result(currentEnv, "/mcp-preview", "resources/read", { uri });
      expect(preview.result.contents[0]).toEqual({ ...resource, uri });
    }

    const missing = await result(currentEnv, "/mcp", "resources/read", { uri: MCP_APP_RESOURCE_URIS.preview });
    expect(missing.error.code).toBe(-32002);
  });

  it.each(["/mcp", "/mcp-preview"] as const)("renders each view on %s", async (path) => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");
    await result(currentEnv, "/mcp", "tools/call", {
      name: "upsert_card",
      arguments: {
        id: "solar",
        template: "summary",
        title: "Solar",
        value: "4.2",
        unit: "kW",
      },
    });

    const card = await result(currentEnv, path, "tools/call", {
      name: "render_card",
      arguments: { id: "solar" },
    });
    expect(card.result.isError).toBeUndefined();
    expect(card.result.structuredContent.card).toMatchObject({ id: "solar", title: "Solar" });
    expect(card.result.content[0].text).toBe("Rendered Solar.");

    await result(currentEnv, "/mcp", "tools/call", {
      name: "start_live_activity",
      arguments: {
        externalActivityId: "washer-cycle",
        kind: "appliance",
        title: "Washer cycle",
        state: "running",
        progress: 0.4,
      },
    });

    const activity = await result(currentEnv, path, "tools/call", {
      name: "render_activity",
      arguments: { externalActivityId: "washer-cycle" },
    });
    expect(activity.result.isError).toBeUndefined();
    expect(activity.result.structuredContent.activity).toMatchObject({
      externalActivityId: "washer-cycle",
      title: "Washer cycle",
      state: "running",
    });
    expect(activity.result.content[0].text).toBe("Rendered Washer cycle.");

    const dashboard = await result(currentEnv, path, "tools/call", {
      name: "render_dashboard",
      arguments: {},
    });
    expect(dashboard.result.structuredContent.cards).toHaveLength(1);
    expect(dashboard.result.structuredContent.activities).toHaveLength(1);
    expect(dashboard.result.content[0].text).toContain("1 card and 1 running activity");

    await result(currentEnv, "/mcp", "tools/call", {
      name: "end_live_activity",
      arguments: { externalActivityId: "washer-cycle" },
    });
    const ended = await result(currentEnv, path, "tools/call", {
      name: "render_activity",
      arguments: { externalActivityId: "washer-cycle" },
    });
    expect(ended.result.isError).toBe(true);
    expect(ended.result.structuredContent).toMatchObject({
      error: "running Live Activity not found",
      status: 404,
      retryable: false,
    });
  });

  it("uses preview-specific OAuth discovery and generated config", async () => {
    const currentEnv = env();
    const catalog = await rpc(currentEnv, "/mcp-preview", {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list",
    }, false);
    expect(catalog.status).toBe(200);
    expect(await catalog.json()).toMatchObject({
      result: { tools: expect.arrayContaining([expect.objectContaining({ name: "render_dashboard" })]) },
    });

    const challenge = await rpc(currentEnv, "/mcp-preview", {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "render_dashboard", arguments: {} },
    }, false);
    expect(challenge.status).toBe(401);
    expect(challenge.headers.get("www-authenticate")).toContain(
      'resource_metadata="https://api.example.com/.well-known/oauth-protected-resource/mcp-preview"',
    );

    const metadata = await fetchWorker(
      new Request("https://api.example.com/.well-known/oauth-protected-resource/mcp-preview"),
      currentEnv,
    );
    expect((await metadata.json() as Record<string, unknown>).resource).toBe(
      "https://api.example.com/mcp-preview",
    );

    const config = await fetchWorker(
      new Request("https://api.example.com/mcp-preview.json"),
      currentEnv,
    );
    expect(await config.json()).toEqual({
      mcpServers: {
        "00widget-preview": {
          type: "http",
          url: "https://api.example.com/mcp-preview",
        },
      },
    });
  });
});
