import { describe, expect, it } from "vitest";
import handler from "../src/index";
import {
  MCP_PREVIEW_LEGACY_RESOURCE_URIS,
  MCP_PREVIEW_RESOURCE_URI,
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

describe("MCP Apps preview channel", () => {
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

  it("does not alter stable discovery even when preview is enabled", async () => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");

    const stableTools = (await result(currentEnv, "/mcp", "tools/list")).result.tools as Array<{
      name: string;
      _meta?: unknown;
    }>;
    expect(stableTools.some((tool) => tool.name === "render_card")).toBe(false);
    expect(stableTools.some((tool) => tool.name === "render_activity")).toBe(false);
    expect(stableTools.some((tool) => tool.name === "render_dashboard")).toBe(false);
    expect(stableTools.every((tool) => tool._meta === undefined)).toBe(true);

    const stableResources = await result(currentEnv, "/mcp", "resources/list");
    expect(stableResources.result.resources).toEqual([]);
    const stableDiscover = await result(currentEnv, "/mcp", "server/discover");
    expect(stableDiscover.result.capabilities).toEqual({ tools: {} });

    const stableCall = await result(currentEnv, "/mcp", "tools/call", {
      name: "render_card",
      arguments: { id: "anything" },
    });
    expect(stableCall.error.code).toBe(-32602);
  });

  it("advertises resources and only three additive render tools", async () => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");

    const preview = await result(currentEnv, "/mcp-preview", "tools/list");
    const tools = preview.result.tools as Array<Record<string, any>>;
    const renderTools = tools.filter((tool) => tool.name.startsWith("render_"));
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
        resourceUri: MCP_PREVIEW_RESOURCE_URI,
        visibility: ["model", "app"],
      });
      expect(tool._meta["ui/resourceUri"]).toBe(MCP_PREVIEW_RESOURCE_URI);
      expect(tool._meta["openai/outputTemplate"]).toBe(MCP_PREVIEW_RESOURCE_URI);
      expect(tool.outputSchema.type).toBe("object");
    }

    const initialized = await result(currentEnv, "/mcp-preview", "initialize", {
      protocolVersion: "2025-06-18",
    });
    expect(initialized.result.capabilities).toEqual({
      tools: { listChanged: false },
      resources: { listChanged: false },
    });
    const discovered = await result(currentEnv, "/mcp-preview", "server/discover");
    expect(discovered.result.capabilities).toEqual({ tools: {}, resources: {} });
  });

  it("serves the versioned self-contained MCP App resource", async () => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");

    const listed = await result(currentEnv, "/mcp-preview", "resources/list");
    expect(listed.result.resources).toEqual([
      expect.objectContaining({
        uri: MCP_PREVIEW_RESOURCE_URI,
        mimeType: "text/html;profile=mcp-app",
        _meta: {
          ui: {
            prefersBorder: false,
            csp: { connectDomains: [], resourceDomains: [] },
          },
        },
      }),
    ]);

    const read = await result(currentEnv, "/mcp-preview", "resources/read", {
      uri: MCP_PREVIEW_RESOURCE_URI,
    });
    const resource = read.result.contents[0];
    expect(resource.uri).toBe(MCP_PREVIEW_RESOURCE_URI);
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
    expect(scripts).toHaveLength(3);
    for (const script of scripts) expect(() => new Function(script)).not.toThrow();

    for (const legacyUri of MCP_PREVIEW_LEGACY_RESOURCE_URIS) {
      const legacy = await result(currentEnv, "/mcp-preview", "resources/read", {
        uri: legacyUri,
      });
      expect(legacy.result.contents[0]).toMatchObject({
        uri: legacyUri,
        mimeType: "text/html;profile=mcp-app",
      });
    }

    const missing = await result(currentEnv, "/mcp-preview", "resources/read", {
      uri: "ui://00widget/preview/not-there.html",
    });
    expect(missing.error.code).toBe(-32002);
  });

  it("renders one card, one running activity, and the dashboard on demand", async () => {
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

    const card = await result(currentEnv, "/mcp-preview", "tools/call", {
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

    const activity = await result(currentEnv, "/mcp-preview", "tools/call", {
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

    const dashboard = await result(currentEnv, "/mcp-preview", "tools/call", {
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
    const ended = await result(currentEnv, "/mcp-preview", "tools/call", {
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
    const challenge = await rpc(currentEnv, "/mcp-preview", {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list",
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
