import { describe, it, expect } from "vitest";
import handler from "../src/index";
import * as storage from "../src/storage";
import type { Env } from "../src/types";
import { authedRequest, makeEnv, seedApiKey, TEST_API_KEY, testApiKey } from "./helpers";
import { llmsMarkdown } from "../src/generated/llmsDoc";

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

  it("requires a credential for every method, discovery included", async () => {
    // ChatGPT authenticates server/discover, tools/list and tools/call alike,
    // so none of them is served anonymously. Only the empty probe is.
    for (const method of ["initialize", "server/discover", "ping", "tools/list"]) {
      const res = await rpc(mcpEnv(), { jsonrpc: "2.0", id: 1, method }, null);
      expect(res.status, method).toBe(401);
      expect(res.headers.get("www-authenticate"), method).toContain("resource_metadata=");
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

  it("answers server/discover in the exact shape the 2026-07-28 revision defines", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 7, method: "server/discover" });
    const body = (await res.json()) as JsonRpcResult;
    expect(body.id).toBe(7);
    // A list of versions, not the single `protocolVersion` the legacy
    // handshake returns. Getting this wrong makes the whole result
    // unparseable to a client, which then never asks for the tools.
    expect(body.result?.supportedVersions).toContain("2026-07-28");
    expect(body.result?.protocolVersion).toBeUndefined();
    expect(body.result?.capabilities).toEqual({ tools: {} });
    // serverInfo lives under its namespaced _meta key, not at the top level.
    expect(body.result?.serverInfo).toBeUndefined();
    const meta = body.result?._meta as Record<string, unknown>;
    expect(meta["io.modelcontextprotocol/serverInfo"]).toMatchObject({ name: "00widget" });
  });

  it("reads the protocol version from namespaced request metadata", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list",
      params: { _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28" } },
    });
    // Recognising the revision is what decides whether 2026-only fields are
    // emitted, so it has to be read from where that revision puts it.
    expect(((await res.json()) as JsonRpcResult).result?.resultType).toBe("complete");
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

  it("flags tools that can overwrite, clear, delete, or replace state as destructive", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    const body = (await res.json()) as JsonRpcResult;
    const tools = body.result?.tools as {
      name: string;
      annotations: { readOnlyHint: boolean; destructiveHint: boolean; idempotentHint: boolean };
    }[];

    const destructive = tools.filter((t) => t.annotations.destructiveHint).map((t) => t.name).sort();
    expect(destructive).toEqual([
      "delete_card",
      "end_live_activity",
      "start_live_activity",
      "update_live_activity",
      "upsert_card",
      "upsert_cards_batch",
    ]);

    const readOnly = tools.filter((t) => t.annotations.readOnlyHint).map((t) => t.name).sort();
    expect(readOnly).toEqual([
      "get_card",
      "get_dashboard",
      "get_integration_guide",
      "get_status",
      "list_cards",
      "list_live_activities",
    ]);
    // A read-only tool must never claim to be destructive.
    for (const tool of tools) {
      if (tool.annotations.readOnlyHint) expect(tool.annotations.destructiveHint, tool.name).toBe(false);
    }

    const nonIdempotent = tools
      .filter((tool) => !tool.annotations.idempotentHint)
      .map((tool) => tool.name)
      .sort();
    expect(nonIdempotent).toEqual(["start_live_activity", "update_live_activity"]);
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

describe("get_dashboard and get_status", () => {
  it("returns cards and activities together", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    await call(env, "upsert_card", { id: "solar", template: "summary", title: "Solar" });
    const result = await call(env, "get_dashboard");
    const body = result.result?.structuredContent as { cards: unknown[]; activities: unknown[] };
    expect(body.cards).toHaveLength(1);
    expect(body.activities).toEqual([]);
  });

  it("tells a connector that nothing can receive what it publishes", async () => {
    // The reason this tool exists. Publishing succeeds either way; only this
    // says whether anyone is on the other end.
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const result = await call(env, "get_status");
    const body = result.result?.structuredContent as {
      delivery: { canPushWidgets: boolean; canStartLiveActivities: boolean };
      account: { scopes: string[] };
    };
    expect(body.delivery.canPushWidgets).toBe(false);
    expect(body.delivery.canStartLiveActivities).toBe(false);
    expect(body.account.scopes).toContain("read");
  });
});

describe("get_integration_guide", () => {
  const guide = async (env: Env, args: Record<string, unknown> = {}) =>
    toolText(await call(env, "get_integration_guide", args));

  it("returns the publishing rules and leaves out the code-level material", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const text = await guide(env);

    for (const heading of [
      "## Data model",
      "## Choosing a template",
      "## Publishing a card",
      "## Live Activities",
      "## Actions",
      "## Errors",
      "## Don'ts",
    ]) {
      expect(text, heading).toContain(heading);
    }
    // A tool caller has typed arguments and an OAuth credential; curl
    // invocations, four language bindings and key setup are all noise it pays
    // for in context.
    for (const heading of [
      "## Snippets",
      "## Get the operator to give you",
      "## Notes for Cloudflare Workers callers",
    ]) {
      expect(text, heading).not.toContain(heading);
    }
    expect(text).not.toContain("curl -X POST");
    // The payload shapes are exactly what the caller is building, so they stay.
    expect(text).toContain("```json");
    expect(text.length).toBeLessThan(llmsMarkdown.length);
  });

  // Regression: a `# ...` shell comment inside a fenced example used to be read
  // as a heading, which truncated the section it sat in and swallowed whichever
  // heading came next — "Live Activities" disappeared from the default guide.
  it("does not mistake shell comments for headings", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    for (const section of ["essentials", "cards", "live-activities", "actions"]) {
      const text = await guide(env, { section });
      const fences = text.split("\n").filter((line) => line.startsWith("```")).length;
      expect(fences % 2, `${section} leaves an unbalanced fence`).toBe(0);
    }
  });

  it("narrows to one section on request", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const activities = await guide(env, { section: "live-activities" });
    expect(activities).toContain("## Live Activities");
    expect(activities).not.toContain("## Choosing a template");
    expect(activities.length).toBeLessThan((await guide(env)).length);
  });

  it("still serves the whole public document on request", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const everything = await guide(env, { section: "everything" });
    expect(everything).toContain("## Snippets");
    expect(everything).toContain("curl -X POST");
  });

  it("rejects a section it does not have", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const result = await call(env, "get_integration_guide", { section: "nonsense" });
    expect(result.result?.isError).toBe(true);
  });
});

describe("failed tool calls", () => {
  it("reports the status and whether retrying can help", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    // A card id the schema refuses: a 400 from the route underneath.
    const result = await call(env, "upsert_card", {
      id: "not a valid id",
      template: "summary",
      title: "x",
    });
    expect(result.result?.isError).toBe(true);
    const detail = result.result?.structuredContent as Record<string, unknown>;
    expect(detail.status).toBe(400);
    // The whole point: a 4xx that is not 429 fails again identically, and a
    // model that retries it just burns the budget.
    expect(detail.retryable).toBe(false);
    // The route's own error body is merged in, so `error` reads as documented.
    expect(String(detail.error)).toContain("validation failed");
  });

  it("carries a rate limit's retry delay as a number", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    // Spend the per-card upsert allowance, then look at what the next one says.
    let result: JsonRpcResult | undefined;
    for (let i = 0; i < 70; i++) {
      result = await call(env, "upsert_card", { id: "hot", template: "summary", title: "x" });
      if (result.result?.isError) break;
    }
    const detail = result?.result?.structuredContent as Record<string, unknown>;
    expect(detail?.status).toBe(429);
    expect(detail.retryable).toBe(true);
    expect(typeof detail.retryAfterSeconds).toBe("number");
    expect(detail.retryAfterSeconds as number).toBeGreaterThan(0);
  });
});

describe("tool input schemas", () => {
  // The schemas are the zod objects the REST routes validate with, converted at
  // module load. A field added without a `.describe()` reaches every MCP client
  // as a bare `{"type":"string"}` — the model then has to guess whether `icon`
  // is a URL or an SF Symbol, and whether `amount` or `value` draws the bar.
  it("declares an output schema for every tool", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    const body = (await res.json()) as JsonRpcResult;
    const tools = body.result?.tools as Array<{ name: string; outputSchema?: unknown }>;

    const missing = tools.filter((tool) => !tool.outputSchema).map((tool) => tool.name);
    expect(missing).toEqual([]);
  });

  it("declares the get_status delivery fields returned by the handler", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    const body = (await res.json()) as JsonRpcResult;
    const tools = body.result?.tools as Array<{
      name: string;
      outputSchema?: {
        properties?: Record<string, { required?: string[] }>;
      };
    }>;
    const delivery = tools.find((tool) => tool.name === "get_status")
      ?.outputSchema?.properties?.delivery;

    expect(delivery?.required).toEqual(expect.arrayContaining([
      "widgetReloadMinSpacingSeconds",
      "widgetReloadBurst",
      "widgetReloadRefillSeconds",
    ]));
    expect(delivery?.required).not.toContain("widgetReloadIntervalSeconds");
  });

  it("returns structured content matching what it declared", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const listed = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    const tools = ((await listed.json()) as JsonRpcResult).result?.tools as Array<{
      name: string;
      outputSchema?: { required?: string[] };
    }>;
    const requiredKeys = (name: string) =>
      tools.find((tool) => tool.name === name)?.outputSchema?.required ?? [];

    const checks: Array<[string, Record<string, unknown>]> = [
      ["upsert_card", { id: "solar", template: "summary", title: "Solar" }],
      ["get_card", { id: "solar" }],
      ["list_cards", {}],
      ["delete_card", { id: "solar" }],
      ["get_integration_guide", { section: "cards" }],
    ];
    for (const [name, args] of checks) {
      const result = await call(env, name, args);
      const structured = result.result?.structuredContent as Record<string, unknown>;
      expect(structured, name).toBeTruthy();
      for (const key of requiredKeys(name)) {
        expect(structured, `${name}.${key}`).toHaveProperty(key);
      }
    }
  });

  it("returns the guide as both readable content and matching structured content", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const result = await call(env, "get_integration_guide", { section: "cards" });
    const markdown = toolText(result);
    const structured = result.result?.structuredContent as Record<string, unknown>;

    expect(markdown).toContain("# 00Widget — cards");
    expect(structured).toEqual({ section: "cards", markdown });
  });

  it("describes every argument a tool accepts", async () => {
    const env = mcpEnv();
    await seedApiKey(env, TEST_API_KEY, "test-tenant");
    const res = await rpc(env, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    const body = (await res.json()) as JsonRpcResult;
    const tools = body.result?.tools as Array<{
      name: string;
      inputSchema: { properties?: Record<string, { description?: string }> };
    }>;
    expect(tools.length).toBeGreaterThan(0);

    const undescribed: string[] = [];
    for (const tool of tools) {
      for (const [field, schema] of Object.entries(tool.inputSchema.properties ?? {})) {
        if (!schema.description) undescribed.push(`${tool.name}.${field}`);
      }
    }
    expect(undescribed).toEqual([]);
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
    expect(one.result?.structuredContent).toMatchObject({ card: { id: "solar" } });
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
      "read",
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

  it("treats an empty POST as a reachability probe, not a failure", async () => {
    // ChatGPT opens the connection this way: content-length 0, no credential.
    // There is no request in it, so there is nothing to refuse.
    for (const contentType of ["application/octet-stream", "application/json"]) {
      const res = await fetchWorker(
        new Request("https://api.example.com/mcp", {
          method: "POST",
          headers: { "content-type": contentType },
          body: "",
        }),
        mcpEnv(),
        ctx,
      );
      expect(res.status, contentType).toBe(202);
      expect(await res.text()).toBe("");
    }
  });

  it("still answers an unparseable anonymous request with the auth challenge", async () => {
    // A client probing the endpoint with an empty or malformed POST has to
    // learn where to authorize. Answering 400 tells it nothing and leaves it
    // with nowhere to go, which is how a connector ends up retrying discovery
    // forever.
    for (const body of ["{oops", "not json at all"]) {
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
      const apiMarker = path === "/" ? "Integrate an app, script, or automation" : "## API integration contract";
      expect(on.indexOf("https://api.example.com/mcp"), path).toBeLessThan(on.indexOf(apiMarker));
      const off = await (await fetchWorker(new Request(`https://api.example.com${path}`), makeEnv(), ctx)).text();
      expect(off, path).not.toContain("/mcp");
    }
  });

  it("keeps the tool contract in llms.md, which the guide tool serves", async () => {
    const res = await fetchWorker(new Request("https://api.example.com/llms.md"), mcpEnv(), ctx);
    expect(await res.text()).toContain("upsert_cards_batch");
  });
});
