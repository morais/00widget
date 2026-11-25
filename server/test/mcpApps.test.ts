import { describe, expect, it } from "vitest";
import { sha256Hex } from "../src/auth";
import handler from "../src/index";
import { MCP_APP_RESOURCE_URI } from "../src/mcpApp";
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

function env(): Env {
  return makeEnv({ MCP_ENABLED: "true", SESSION_SECRET });
}

async function result(
  currentEnv: Env,
  method: string,
  params?: unknown,
): Promise<Record<string, any>> {
  const req = authedRequest("https://api.example.com/mcp", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  }, TEST_API_KEY);
  const res = await fetchWorker(req, currentEnv);
  return await res.json() as Record<string, any>;
}

describe("MCP Apps", () => {
  it("returns 404 for the retired preview URLs", async () => {
    const currentEnv = env();
    const routes = [
      ["POST", "/mcp-preview"],
      ["GET", "/mcp-preview"],
      ["GET", "/mcp-preview.json"],
      ["GET", "/.well-known/oauth-protected-resource/mcp-preview"],
    ];
    for (const [method, path] of routes) {
      for (const suffix of ["", "/"]) {
        const response = await fetchWorker(new Request(`https://api.example.com${path}${suffix}`, {
          method,
        }), currentEnv);
        expect(response.status, `${method} ${path}${suffix}`).toBe(404);
      }
    }
  });

  it("preserves all published tool descriptors in order", async () => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");

    // Captured from production /mcp before the preview URLs were retired.
    const { tools } = (await result(currentEnv, "tools/list")).result;
    expect(await sha256Hex(JSON.stringify(tools))).toBe(
      "fa07e42b0953ee3a3ad42d4429497fe9f16132602b30718a96b67b67e72b112f",
    );
  });

  it("advertises resources and three render tools on /mcp", async () => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");

    const stable = await result(currentEnv, "tools/list");
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
        resourceUri: MCP_APP_RESOURCE_URI,
        visibility: ["model", "app"],
      });
      expect(tool._meta["ui/resourceUri"]).toBe(MCP_APP_RESOURCE_URI);
      expect(tool._meta["openai/outputTemplate"]).toBe(MCP_APP_RESOURCE_URI);
      expect(tool.outputSchema.type).toBe("object");
    }

    const initialized = await result(currentEnv, "initialize", {
      protocolVersion: "2025-06-18",
    });
    expect(initialized.result.capabilities).toEqual({
      tools: { listChanged: false },
      resources: { listChanged: false },
    });
    const discovered = await result(currentEnv, "server/discover");
    expect(discovered.result.capabilities).toEqual({ tools: {}, resources: {} });
  });

  it("serves the versioned self-contained MCP App resource", async () => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");

    const listed = await result(currentEnv, "resources/list");
    expect(listed.result.resources).toEqual([
      expect.objectContaining({
        uri: MCP_APP_RESOURCE_URI,
        mimeType: "text/html;profile=mcp-app",
        _meta: {
          ui: {
            prefersBorder: false,
            csp: { connectDomains: [], resourceDomains: [] },
          },
        },
      }),
    ]);

    const read = await result(currentEnv, "resources/read", {
      uri: MCP_APP_RESOURCE_URI,
    });
    expect(Object.keys(read.result)).toEqual(["contents"]);
    const modern = await result(currentEnv, "resources/read", {
      uri: MCP_APP_RESOURCE_URI,
      _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28" },
    });
    expect(modern.result).toEqual({
      contents: read.result.contents,
      resultType: "complete",
      ttlMs: 3600000,
      cacheScope: "public",
    });
    const resource = read.result.contents[0];
    expect(resource.uri).toBe(MCP_APP_RESOURCE_URI);
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

    const missing = await result(currentEnv, "resources/read", { uri: "ui://00widget/preview/v1-preview.3.html" });
    expect(missing.error.code).toBe(-32002);
  });

  it("renders each view on /mcp", async () => {
    const currentEnv = env();
    await seedApiKey(currentEnv, TEST_API_KEY, "test-tenant");
    await result(currentEnv, "tools/call", {
      name: "upsert_card",
      arguments: {
        id: "solar",
        template: "summary",
        title: "Solar",
        value: "4.2",
        unit: "kW",
      },
    });

    const card = await result(currentEnv, "tools/call", {
      name: "render_card",
      arguments: { id: "solar" },
    });
    expect(card.result.isError).toBeUndefined();
    expect(card.result.structuredContent.card).toMatchObject({ id: "solar", title: "Solar" });
    expect(card.result.content[0].text).toBe("Rendered Solar.");

    await result(currentEnv, "tools/call", {
      name: "start_live_activity",
      arguments: {
        externalActivityId: "washer-cycle",
        kind: "appliance",
        title: "Washer cycle",
        state: "running",
        progress: 0.4,
      },
    });

    const activity = await result(currentEnv, "tools/call", {
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

    const dashboard = await result(currentEnv, "tools/call", {
      name: "render_dashboard",
      arguments: {},
    });
    expect(dashboard.result.structuredContent.cards).toHaveLength(1);
    expect(dashboard.result.structuredContent.activities).toHaveLength(1);
    expect(dashboard.result.content[0].text).toContain("1 card and 1 running activity");

    await result(currentEnv, "tools/call", {
      name: "end_live_activity",
      arguments: { externalActivityId: "washer-cycle" },
    });
    const ended = await result(currentEnv, "tools/call", {
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
});
