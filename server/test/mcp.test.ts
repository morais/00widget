import { describe, it, expect } from "vitest";
import handler from "../src/index";
import * as storage from "../src/storage";
import type { Env } from "../src/types";
import { authedRequest, makeEnv, seedApiKey, TEST_API_KEY, testApiKey } from "./helpers";

const ctx = {} as ExecutionContext;

// `handler.fetch` is typed for a real edge request; these are plain ones.
function fetchWorker(req: Request, env: Env, executionCtx: ExecutionContext): Promise<Response> {
  return (handler.fetch as (r: Request, e: Env, c: ExecutionContext) => Promise<Response>)(
    req,
    env,
    executionCtx,
  );
}

const SESSION_SECRET = "test-session-secret-0123456789abcdef";

function mcpEnv(overrides: Partial<Env> = {}): Env {
  return makeEnv({ MCP_ENABLED: "true", SESSION_SECRET, ...overrides });
}

interface JsonRpcResult {
  jsonrpc: string;
  id: string | number | null;
  result?: Record<string, unknown>;
  error?: { code: number; message: string };
}

async function rpc(
  env: Env,
  body: unknown,
  apiKey: string | null = TEST_API_KEY,
): Promise<Response> {
  const init: RequestInit = { method: "POST", body: JSON.stringify(body) };
  const req = apiKey === null
    ? new Request("https://api.example.com/mcp", {
        ...init,
        headers: { "content-type": "application/json" },
      })
    : authedRequest("https://api.example.com/mcp", init, apiKey);
  return fetchWorker(req, env, ctx);
}

async function call(
  env: Env,
  name: string,
  args: Record<string, unknown> = {},
  apiKey: string | null = TEST_API_KEY,
): Promise<JsonRpcResult> {
  const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }, apiKey);
  return (await res.json()) as JsonRpcResult;
}

function toolText(result: JsonRpcResult): string {
  const content = result.result?.content as { type: string; text: string }[] | undefined;
  return content?.map((entry) => entry.text).join("") ?? "";
}

describe("MCP endpoint gating", () => {
  it("404s when MCP_ENABLED is not set, even with a valid credential", async () => {
    const env = makeEnv({ SESSION_SECRET });
    const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    expect(res.status).toBe(404);
  });

  it("404s when enabled without a usable SESSION_SECRET, because it could never be authorized", async () => {
    const env = makeEnv({ MCP_ENABLED: "true", SESSION_SECRET: "short" });
    const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    expect(res.status).toBe(404);
  });

  it("answers GET with 405 rather than 404, so a client probing for SSE learns the endpoint exists", async () => {
    const res = await fetchWorker(new Request("https://api.example.com/mcp"), mcpEnv(), ctx);
    expect(res.status).toBe(405);
    expect(res.headers.get("allow")).toBe("POST");
  });
});

describe("MCP authentication", () => {
  it("challenges an anonymous tools/call with the metadata pointer that starts OAuth", async () => {
    const res = await rpc(
      mcpEnv(),
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_cards", arguments: {} } },
      null,
    );
    expect(res.status).toBe(401);
    const challenge = res.headers.get("www-authenticate") ?? "";
    expect(challenge).toContain("Bearer");
    expect(challenge).toContain(
      'resource_metadata="https://api.example.com/.well-known/oauth-protected-resource"',
    );
  });

  it("lets an anonymous caller read the tool list, which is the same for everyone", async () => {
    // ChatGPT fetches the list with no credential; refusing it leaves the
    // connector with no tools to offer. The list is generated from static
    // schemas and describes only what /llms.md already publishes.
    const res = await rpc(mcpEnv(), { jsonrpc: "2.0", id: 1, method: "tools/list" }, null);
    expect(res.status).toBe(200);
    const tools = ((await res.json()) as JsonRpcResult).result?.tools as { name: string }[];
    expect(tools.map((tool) => tool.name)).toContain("upsert_card");
  });

  it("lets an anonymous caller initialize and discover", async () => {
    for (const method of ["initialize", "server/discover", "ping"]) {
      const res = await rpc(mcpEnv(), { jsonrpc: "2.0", id: 1, method }, null);
      expect(res.status, method).toBe(200);
      expect(((await res.json()) as JsonRpcResult).error, method).toBeUndefined();
    }
  });

  it("never runs a tool for an anonymous caller", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(
      env,
      {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "upsert_card", arguments: { id: "sneak", template: "summary", title: "X" } },
      },
      null,
    );
    expect(res.status).toBe(401);
    expect(await storage.getCard(env, "test-tenant", "sneak")).toBeNull();
  });

  it("challenges an invalid token the same way", async () => {
    const res = await rpc(mcpEnv(), { jsonrpc: "2.0", id: 1, method: "tools/list" }, testApiKey("nope"));
    expect(res.status).toBe(401);
    expect(res.headers.get("www-authenticate")).toContain("resource_metadata=");
  });

  it("never caches a response from the endpoint", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    expect(res.headers.get("cache-control")).toBe("no-store");
  });
});

describe("MCP handshake", () => {
  it("echoes a protocol version it speaks", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18", clientInfo: { name: "chatgpt", version: "1" } },
    });
    const body = (await res.json()) as JsonRpcResult;
    expect(body.result?.protocolVersion).toBe("2025-06-18");
    expect(body.result?.serverInfo).toMatchObject({ name: "00widget" });
  });

  it("falls back to the newest version it speaks when asked for one it does not", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "1999-01-01" },
    });
    const body = (await res.json()) as JsonRpcResult;
    expect(body.result?.protocolVersion).toBe("2026-07-28");
  });

  it("answers the post-handshake server/discover of the 2026-07-28 revision", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 7, method: "server/discover" });
    const body = (await res.json()) as JsonRpcResult;
    expect(body.id).toBe(7);
    expect(body.result?.protocolVersion).toBe("2026-07-28");
    expect(body.result?.capabilities).toMatchObject({ tools: {} });
  });

  it("returns no body for a notification", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", method: "notifications/initialized" });
    expect(res.status).toBe(202);
    expect(await res.text()).toBe("");
  });

  it("sends 2026-07-28 result fields only to clients that speak it", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");

    const older = await rpc(env, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18" },
    });
    // `resultType` is not in that revision's schema; a strict client validating
    // against it should not be handed a field it has never heard of.
    expect(((await older.json()) as JsonRpcResult).result?.resultType).toBeUndefined();

    const newer = await rpc(env, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2026-07-28" },
    });
    expect(((await newer.json()) as JsonRpcResult).result?.resultType).toBe("complete");
  });

  it("reads the negotiated revision from the transport header too", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const req = authedRequest("https://api.example.com/mcp", {
      method: "POST",
      headers: { "mcp-protocol-version": "2026-07-28" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
    });
    const body = (await (await fetchWorker(req, env, ctx)).json()) as JsonRpcResult;
    expect(body.result?.resultType).toBe("complete");
  });

  it("answers the list methods it does not implement with empty lists, not errors", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    for (const [method, key] of [
      ["resources/list", "resources"],
      ["resources/templates/list", "resourceTemplates"],
      ["prompts/list", "prompts"],
    ]) {
      const res = await rpc(env, { jsonrpc: "2.0", id: 3, method });
      const body = (await res.json()) as JsonRpcResult;
      // A client that probes these should learn there are none, not that the
      // server is broken.
      expect(body.error, method).toBeUndefined();
      expect(body.result?.[key], method).toEqual([]);
    }
  });

  it("rejects an unknown method with -32601", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 2, method: "sampling/createMessage" });
    const body = (await res.json()) as JsonRpcResult;
    expect(body.error?.code).toBe(-32601);
  });
});

describe("tools/list", () => {
  it("advertises a valid JSON Schema for every tool", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    const body = (await res.json()) as JsonRpcResult;
    const tools = body.result?.tools as { name: string; inputSchema: Record<string, unknown> }[];
    expect(tools.length).toBeGreaterThan(0);
    for (const tool of tools) {
      // The schemas are converted from the same zod objects the REST routes
      // validate with; a conversion that silently produced nothing would leave
      // a tool the model cannot call correctly.
      expect(tool.inputSchema.type, tool.name).toBe("object");
      expect(tool.inputSchema.$schema, tool.name).toBeUndefined();
    }
    expect(tools.map((tool) => tool.name)).toEqual(
      expect.arrayContaining(["upsert_card", "upsert_cards_batch", "start_live_activity", "get_integration_guide"]),
    );
  });

  it("carries the card fields through from the shared zod schema", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    const body = (await res.json()) as JsonRpcResult;
    const tools = body.result?.tools as { name: string; inputSchema: Record<string, unknown> }[];
    const upsert = tools.find((tool) => tool.name === "upsert_card")!;
    const properties = upsert.inputSchema.properties as Record<string, unknown>;
    expect(Object.keys(properties)).toEqual(
      expect.arrayContaining(["id", "template", "title", "status", "items", "chart", "deepLink"]),
    );
    expect(upsert.inputSchema.required).toEqual(expect.arrayContaining(["id", "template", "title"]));
  });
});

describe("tools/call", () => {
  it("publishes a card through the same handler the REST route uses", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const result = await call(env, "upsert_card", {
      id: "solar",
      template: "summary",
      title: "Solar",
      value: "3.2",
      unit: "kW",
      status: "good",
    });
    expect(result.error).toBeUndefined();
    expect(result.result?.isError).toBeUndefined();
    const stored = await storage.getCard(env, "test-tenant", "solar");
    expect(stored?.title).toBe("Solar");
    // The tool's structured result is the endpoint's own JSON body.
    expect(result.result?.structuredContent).toMatchObject({ card: { id: "solar" } });
  });

  it("publishes a batch in one call", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const result = await call(env, "upsert_cards_batch", {
      cards: [
        { id: "a", template: "summary", title: "A" },
        { id: "b", template: "summary", title: "B" },
      ],
    });
    expect(result.result?.isError).toBeUndefined();
    expect(await storage.getCard(env, "test-tenant", "a")).toBeTruthy();
    expect(await storage.getCard(env, "test-tenant", "b")).toBeTruthy();
  });

  it("reads cards back", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    await call(env, "upsert_card", { id: "solar", template: "summary", title: "Solar" });
    const listed = await call(env, "list_cards");
    expect(toolText(listed)).toContain("solar");
    const one = await call(env, "get_card", { id: "solar" });
    expect(one.result?.structuredContent).toMatchObject({ id: "solar" });
  });

  it("deletes a card", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    await call(env, "upsert_card", { id: "gone", template: "summary", title: "Gone" });
    await call(env, "delete_card", { id: "gone" });
    expect(await storage.getCard(env, "test-tenant", "gone")).toBeNull();
  });

  it("reports bad arguments as a tool error the model can retry, not a transport error", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const result = await call(env, "upsert_card", { id: "x", template: "exotic", title: "X" });
    expect(result.error).toBeUndefined();
    expect(result.result?.isError).toBe(true);
    expect(toolText(result)).toContain("validation failed");
  });

  it("reports a missing scope as a protocol error, because no argument fixes it", async () => {
    const env = mcpEnv();
    await seedApiKey(env, "readonly", "test-tenant", "publisher", "", "", "2099-01-01T00:00:00.000Z", [
      "tenant:read",
    ]);
    const result = await call(
      env,
      "upsert_card",
      { id: "x", template: "summary", title: "X" },
      testApiKey("readonly"),
    );
    expect(result.result).toBeUndefined();
    expect(result.error?.message).toContain("publish");
    expect(await storage.getCard(env, "test-tenant", "x")).toBeNull();
  });

  it("rejects an unknown tool name", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const result = await call(env, "drop_database");
    expect(result.error?.code).toBe(-32602);
  });

  it("serves the integration guide with this deployment's own base URL", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const result = await call(env, "get_integration_guide");
    const text = toolText(result);
    expect(text).toContain("00WIDGET_BASE_URL=https://api.example.com");
    expect(text).not.toContain("https://api.example.com/llms.md is unavailable");
  });

  it("keeps one tenant's cards out of another's reach", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "tenant-a");
    await seedApiKey(env, "other", "tenant-b");
    await call(env, "upsert_card", { id: "private", template: "summary", title: "Private" });
    const listed = await call(env, "list_cards", {}, testApiKey("other"));
    expect(toolText(listed)).not.toContain("private");
  });
});

describe("JSON-RPC framing", () => {
  it("handles a batch, dropping the notifications from the response", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, [
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 1, method: "tools/list" },
    ]);
    const body = (await res.json()) as JsonRpcResult[];
    expect(Array.isArray(body)).toBe(true);
    expect(body).toHaveLength(1);
    expect(body[0].id).toBe(1);
  });

  it("rejects a malformed body with -32700 once the caller is authenticated", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const req = authedRequest("https://api.example.com/mcp", { method: "POST", body: "{oops" });
    const res = await fetchWorker(req, env, ctx);
    expect(res.status).toBe(400);
    expect(((await res.json()) as JsonRpcResult).error?.code).toBe(-32700);
  });

  it("still answers an unparseable anonymous request with the auth challenge", async () => {
    // A client probing the endpoint with an empty or malformed POST has to
    // learn where to authorize. Answering 400 tells it nothing and leaves it
    // with nowhere to go, which is how a connector ends up retrying discovery
    // forever.
    for (const body of ["", "{oops"]) {
      const res = await fetchWorker(
        new Request("https://api.example.com/mcp", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body,
        }),
        mcpEnv(),
        ctx,
      );
      expect(res.status, JSON.stringify(body)).toBe(401);
      expect(res.headers.get("www-authenticate"), JSON.stringify(body)).toContain("resource_metadata=");
    }
  });
});

describe("GET /mcp.json", () => {
  it("names the host it was fetched from", async () => {
    const res = await fetchWorker(
      new Request("https://staging.example.org/mcp.json"),
      mcpEnv(),
      ctx,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { mcpServers: Record<string, { url: string; type: string }> };
    expect(body.mcpServers["00widget"].url).toBe("https://staging.example.org/mcp");
    expect(body.mcpServers["00widget"].type).toBe("http");
  });

  it("404s when MCP is disabled", async () => {
    const res = await fetchWorker(new Request("https://api.example.com/mcp.json"), makeEnv(), ctx);
    expect(res.status).toBe(404);
  });
});

describe("advertising the endpoint", () => {
  it("mentions MCP on the landing page and in llms.txt only where it is enabled", async () => {
    for (const path of ["/", "/llms.txt"]) {
      const on = await (await fetchWorker(new Request(`https://api.example.com${path}`), mcpEnv(), ctx)).text();
      expect(on, path).toContain("https://api.example.com/mcp");
      const off = await (await fetchWorker(new Request(`https://api.example.com${path}`), makeEnv(), ctx)).text();
      expect(off, path).not.toContain("/mcp");
    }
  });

  it("keeps the tool contract in llms.md, which the guide tool serves", async () => {
    const res = await fetchWorker(new Request("https://api.example.com/llms.md"), mcpEnv(), ctx);
    expect(await res.text()).toContain("upsert_cards_batch");
  });
});
