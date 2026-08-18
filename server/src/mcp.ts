import { z } from "zod";
import {
  AuthError,
  AuthRateLimitError,
  hasScope,
  requireAuth,
  type ApiScope,
  type AuthContext,
} from "./auth";
import * as cards from "./cards";
import * as liveActivities from "./liveActivities";
import { json } from "./http";
import { renderHostedLlmsMarkdown } from "./landing";
import { mcpConfigured, mcpUnauthorized } from "./mcpOAuth";
import {
  BatchUpsertCardsSchema,
  DashboardCardInputSchema,
  EndLiveActivitySchema,
  RequestBodyLimits,
  StartLiveActivitySchema,
  UpdateLiveActivitySchema,
  type Env,
} from "./types";

// Model Context Protocol endpoint, so an agent that speaks MCP (ChatGPT,
// Claude, an IDE) can publish to 00Widget without anyone writing a client.
//
// The tools are an *adapter over the HTTP handlers*, not a second
// implementation: each one builds the request the equivalent /v1 route would
// have received and calls the same function `index.ts` calls. Validation,
// field limits, rate limits and the one-reload-per-batch semantics therefore
// cannot drift from the REST surface, because they are the same code. The
// argument schemas are the same zod objects too, converted to JSON Schema at
// module load — a field added to a card shows up in the tool contract with no
// edit here.
//
// The transport is stateless Streamable HTTP: one POST in, one JSON response
// out, no SSE stream and no session id. That is both what a Worker can honestly
// offer (there is nowhere to keep a session) and where the protocol went — the
// 2026-07-28 revision removed the initialize handshake and session header
// outright. Older clients that still open with `initialize` are answered too;
// both spellings are cheap to support and the wire shapes barely differ.

export const MCP_PATH = "/mcp";

const SERVER_NAME = "00widget";
const SERVER_VERSION = "1.0.0";

// Newest first. An `initialize` naming a version in this list is echoed back;
// anything else is answered with the newest, which is what the spec asks a
// server to do when it cannot speak what the client proposed.
const SUPPORTED_PROTOCOL_VERSIONS = [
  "2026-07-28",
  "2025-11-25",
  "2025-06-18",
  "2025-03-26",
] as const;
const LATEST_PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS[0];

// tools/list is a pure function of this file, so clients may cache it. The
// 2026-07-28 revision reads these fields; older ones ignore them.
const TOOL_LIST_TTL_MS = 60 * 60 * 1000;

const JSON_RPC_PARSE_ERROR = -32700;
const JSON_RPC_INVALID_REQUEST = -32600;
const JSON_RPC_METHOD_NOT_FOUND = -32601;
const JSON_RPC_INVALID_PARAMS = -32602;
const JSON_RPC_INTERNAL_ERROR = -32603;

interface JsonRpcRequest {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: unknown;
}

interface ToolContext {
  env: Env;
  auth: AuthContext;
  ctx: ExecutionContext;
  origin: string;
}

interface McpTool {
  name: string;
  title: string;
  description: string;
  schema: z.ZodType;
  scope: ApiScope;
  readOnly: boolean;
  invoke(args: Record<string, unknown>, tools: ToolContext): Promise<Response>;
}

const NoArguments = z.object({});

const TOOLS: McpTool[] = [
  {
    name: "list_cards",
    title: "List cards",
    description:
      "List every dashboard card this credential's tenant has published, as stored. Use it to "
      + "discover the ids already in use before publishing, and to read back what a widget shows.",
    schema: z.object({
      includeShared: z
        .boolean()
        .optional()
        .describe("Also return cards other tenants have shared with this one, when sharing is enabled."),
    }),
    scope: "tenant:read",
    readOnly: true,
    invoke: (args, tools) =>
      cards.listCards(
        getRequest(tools.origin, args.includeShared ? "/v1/cards?include=shared" : "/v1/cards"),
        tools.env,
        tools.auth,
      ),
  },
  {
    name: "get_card",
    title: "Get a card",
    description: "Read one published card by its stable id.",
    schema: z.object({ id: z.string().min(1).describe("The card's stable id.") }),
    scope: "tenant:read",
    readOnly: true,
    invoke: (args, tools) =>
      cards.getCard(getRequest(tools.origin, "/v1/cards"), tools.env, tools.auth, String(args.id)),
  },
  {
    name: "upsert_card",
    title: "Publish a card",
    description:
      "Create or replace one dashboard card. The `id` is the identity of the thing being shown, so "
      + "reuse it on every publish — never embed a timestamp or run id, or each update becomes a new "
      + "card. Publishing several cards from one snapshot? Use upsert_cards_batch instead.",
    schema: DashboardCardInputSchema,
    scope: "publish",
    readOnly: false,
    invoke: (args, tools) =>
      cards.upsertCard(postRequest(tools.origin, "/v1/cards/upsert", args), tools.env, tools.auth, tools.ctx),
  },
  {
    name: "upsert_cards_batch",
    title: "Publish several cards at once",
    description:
      "Create or replace up to 32 cards in one call. Always prefer this over repeated upsert_card "
      + "when one snapshot produces several related cards: it makes a single widget-reload decision "
      + "instead of burning WidgetKit's daily reload budget once per card.",
    schema: BatchUpsertCardsSchema,
    scope: "publish",
    readOnly: false,
    invoke: (args, tools) =>
      cards.upsertCardsBatch(
        postRequest(tools.origin, "/v1/cards/upsert-batch", args),
        tools.env,
        tools.auth,
        tools.ctx,
      ),
  },
  {
    name: "delete_card",
    title: "Delete a card",
    description: "Remove a published card. Widgets showing it stop showing it.",
    schema: z.object({ id: z.string().min(1).describe("The card's stable id.") }),
    scope: "publish",
    readOnly: false,
    invoke: (args, tools) =>
      cards.deleteCard(
        getRequest(tools.origin, "/v1/cards"),
        tools.env,
        tools.auth,
        String(args.id),
        tools.ctx,
      ),
  },
  {
    name: "list_live_activities",
    title: "List running Live Activities",
    description: "List the Live Activities this tenant currently has running, with their content state.",
    schema: NoArguments,
    scope: "tenant:read",
    readOnly: true,
    invoke: (_args, tools) =>
      liveActivities.activeActivities(getRequest(tools.origin, "/v1/live-activities"), tools.env, tools.auth),
  },
  {
    name: "start_live_activity",
    title: "Start a Live Activity",
    description:
      "Start a Live Activity on the Lock Screen and Dynamic Island. Use this only for something "
      + "time-bounded with a clear end — a build, a wash cycle, a charge, a delivery — and always end "
      + "it. `title`, `kind` and `deepLink` are frozen when it starts and cannot be changed by an "
      + "update, so anything that must move belongs in the content state fields.",
    schema: StartLiveActivitySchema,
    scope: "publish",
    readOnly: false,
    invoke: (args, tools) =>
      liveActivities.startLiveActivity(
        postRequest(tools.origin, "/v1/live-activities/start", args),
        tools.env,
        tools.auth,
      ),
  },
  {
    name: "update_live_activity",
    title: "Update a Live Activity",
    description:
      "Push new content state to a running Live Activity. A new `title` is stored and returned by "
      + "list_live_activities but the Lock Screen keeps the original — it is frozen at start.",
    schema: UpdateLiveActivitySchema,
    scope: "publish",
    readOnly: false,
    invoke: (args, tools) =>
      liveActivities.updateLiveActivity(
        postRequest(tools.origin, "/v1/live-activities/update", args),
        tools.env,
        tools.auth,
      ),
  },
  {
    name: "end_live_activity",
    title: "End a Live Activity",
    description: "End a running Live Activity with a final frame. Always end what you start.",
    schema: EndLiveActivitySchema,
    scope: "publish",
    readOnly: false,
    invoke: (args, tools) =>
      liveActivities.endLiveActivity(
        postRequest(tools.origin, "/v1/live-activities/end", args),
        tools.env,
        tools.auth,
      ),
  },
  {
    name: "get_integration_guide",
    title: "Read the 00Widget integration guide",
    description:
      "Return the full 00Widget integration contract: every card template with its fields, the "
      + "decision matrix for picking one, Live Activity rules, and publishing etiquette. Read this "
      + "before publishing anything for the first time.",
    schema: NoArguments,
    scope: "tenant:read",
    readOnly: true,
    invoke: async (_args, tools) =>
      new Response(renderHostedLlmsMarkdown(tools.origin), {
        headers: { "content-type": "text/markdown; charset=utf-8" },
      }),
  },
];

// Converted once per isolate. `io: "input"` describes what a caller may send —
// fields carrying a zod default are optional here even though they are always
// present in the stored card.
const TOOL_DESCRIPTORS = TOOLS.map((tool) => ({
  name: tool.name,
  title: tool.title,
  description: tool.description,
  inputSchema: toolInputSchema(tool.schema),
  annotations: {
    title: tool.title,
    readOnlyHint: tool.readOnly,
    destructiveHint: tool.name === "delete_card",
    idempotentHint: !tool.readOnly,
    openWorldHint: false,
  },
}));

function toolInputSchema(schema: z.ZodType): Record<string, unknown> {
  const converted = z.toJSONSchema(schema, { io: "input" }) as Record<string, unknown>;
  // MCP wants a bare JSON Schema object; the $schema declaration is noise that
  // some clients reject outright.
  delete converted.$schema;
  return converted;
}

// ---------- Discovery for humans and non-ChatGPT clients ----------

/// A ready-to-paste MCP client config for whatever host is serving it. Clients
/// that take a config file (Claude Code, editors) want this shape; ChatGPT is
/// pointed at the URL directly. Generated per request so a fork or a staging
/// deployment hands out its own hostname rather than one hardcoded here.
export async function handleMcpConfig(req: Request, env: Env): Promise<Response> {
  if (!mcpConfigured(env)) return json({ error: "not found" }, 404);
  const origin = new URL(req.url).origin;
  return json(
    {
      mcpServers: {
        "00widget": {
          type: "http",
          url: `${origin}${MCP_PATH}`,
        },
      },
    },
    200,
    { "cache-control": "public, max-age=300" },
  );
}

/// The MCP endpoint speaks one POST at a time. Answering GET with a clean 405
/// (rather than the router's 404) tells a client probing for an SSE stream that
/// the endpoint exists and which method it wants.
export async function handleMcpMethodNotAllowed(_req: Request, env: Env): Promise<Response> {
  if (!mcpConfigured(env)) return json({ error: "not found" }, 404);
  return json(
    { error: "the MCP endpoint accepts POST only; this server has no SSE stream" },
    405,
    { allow: "POST" },
  );
}

// ---------- Transport ----------

export async function handleMcp(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (!mcpConfigured(env)) return json({ error: "not found" }, 404);

  let payload: unknown;
  try {
    payload = JSON.parse(await readBodyUpTo(req, RequestBodyLimits.mcpRpc));
  } catch {
    return json(errorResponse(null, JSON_RPC_PARSE_ERROR, "invalid JSON body"), 400);
  }

  // A batch of notifications alone gets an empty 202, so authenticate first
  // only when the batch actually asks for something. Every method this server
  // implements needs a tenant, including tools/list.
  let auth: AuthContext;
  try {
    auth = await requireAuth(req, env);
  } catch (err) {
    if (err instanceof AuthRateLimitError) {
      return json({ error: err.message }, 429, { "retry-after": "60" });
    }
    if (err instanceof AuthError) return mcpUnauthorized(req, err.message);
    throw err;
  }

  const origin = new URL(req.url).origin;
  const tools: ToolContext = { env, auth, ctx, origin };

  if (Array.isArray(payload)) {
    if (payload.length === 0) {
      return json(errorResponse(null, JSON_RPC_INVALID_REQUEST, "empty batch"), 400);
    }
    const responses = [];
    for (const entry of payload) {
      const result = await dispatch(entry as JsonRpcRequest, tools);
      if (result) responses.push(result);
    }
    if (responses.length === 0) return new Response(null, { status: 202 });
    return json(responses);
  }

  const result = await dispatch(payload as JsonRpcRequest, tools);
  if (!result) return new Response(null, { status: 202 });
  return json(result);
}

/// Returns null for notifications, which JSON-RPC answers with no body at all.
async function dispatch(
  request: JsonRpcRequest,
  tools: ToolContext,
): Promise<Record<string, unknown> | null> {
  if (!request || typeof request !== "object" || typeof request.method !== "string") {
    return errorResponse(null, JSON_RPC_INVALID_REQUEST, "not a JSON-RPC request");
  }
  const id = request.id ?? null;
  const isNotification = request.id === undefined || request.id === null;

  switch (request.method) {
    // Pre-2026-07-28 handshake. Answered for compatibility; nothing is stored.
    case "initialize":
      return successResponse(id, {
        protocolVersion: negotiatedProtocolVersion(request.params),
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        instructions:
          "Publish project state to the operator's iOS widgets and Live Activities. Call "
          + "get_integration_guide first to learn the card templates and their fields.",
      });
    // 2026-07-28 replacement for the handshake.
    case "server/discover":
      return successResponse(id, {
        protocolVersion: LATEST_PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
    case "notifications/initialized":
    case "notifications/cancelled":
      return null;
    case "ping":
      return isNotification ? null : successResponse(id, {});
    case "tools/list":
      return successResponse(id, {
        tools: TOOL_DESCRIPTORS,
        ttlMs: TOOL_LIST_TTL_MS,
        cacheScope: "public",
      });
    case "tools/call":
      return await callTool(id, request.params, tools);
    default:
      if (isNotification) return null;
      return errorResponse(id, JSON_RPC_METHOD_NOT_FOUND, `unknown method '${request.method}'`);
  }
}

async function callTool(
  id: string | number | null,
  params: unknown,
  tools: ToolContext,
): Promise<Record<string, unknown>> {
  const call = (params ?? {}) as { name?: unknown; arguments?: unknown };
  if (typeof call.name !== "string") {
    return errorResponse(id, JSON_RPC_INVALID_PARAMS, "params.name is required");
  }
  const tool = TOOLS.find((candidate) => candidate.name === call.name);
  if (!tool) {
    return errorResponse(id, JSON_RPC_INVALID_PARAMS, `unknown tool '${call.name}'`);
  }
  const args = (call.arguments ?? {}) as Record<string, unknown>;
  if (typeof args !== "object" || Array.isArray(args)) {
    return errorResponse(id, JSON_RPC_INVALID_PARAMS, "params.arguments must be an object");
  }

  // A scope failure is a protocol-level error, not a tool result: the model
  // cannot fix it by trying different arguments, and the operator has to issue
  // a different credential.
  if (!hasScope(tools.auth, tool.scope)) {
    return errorResponse(id, JSON_RPC_INVALID_REQUEST, `API scope '${tool.scope}' required`);
  }

  // Validated here as well as inside the handler so an argument mistake comes
  // back as a tool error the model can act on, rather than as a bare 400.
  const parsed = tool.schema.safeParse(args);
  if (!parsed.success) {
    return successResponse(id, toolError(`validation failed: ${parsed.error.message}`));
  }

  let response: Response;
  try {
    response = await tool.invoke(args, tools);
  } catch (err) {
    console.error("mcp tool failed", { tool: tool.name, error: String(err) });
    return errorResponse(id, JSON_RPC_INTERNAL_ERROR, "internal error");
  }

  const contentType = response.headers.get("content-type") ?? "";
  const text = await response.text();
  if (!response.ok) {
    return successResponse(id, toolError(text || `request failed with ${response.status}`));
  }
  if (!contentType.includes("application/json")) {
    return successResponse(id, { content: [{ type: "text", text }] });
  }
  let structured: unknown;
  try {
    structured = JSON.parse(text);
  } catch {
    return successResponse(id, { content: [{ type: "text", text }] });
  }
  return successResponse(id, {
    content: [{ type: "text", text }],
    structuredContent: structured,
  });
}

function toolError(message: string): Record<string, unknown> {
  return { content: [{ type: "text", text: message }], isError: true };
}

function negotiatedProtocolVersion(params: unknown): string {
  const asked = (params as { protocolVersion?: unknown } | undefined)?.protocolVersion;
  if (typeof asked === "string" && (SUPPORTED_PROTOCOL_VERSIONS as readonly string[]).includes(asked)) {
    return asked;
  }
  return LATEST_PROTOCOL_VERSION;
}

function successResponse(id: string | number | null, result: Record<string, unknown>) {
  // `resultType` is required from 2026-07-28 and ignored before it. This server
  // never asks the client for input mid-call, so every result is complete.
  return { jsonrpc: "2.0", id, result: { resultType: "complete", ...result } };
}

function errorResponse(id: string | number | null, code: number, message: string) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

// ---------- Bridging to the HTTP handlers ----------

function getRequest(origin: string, path: string): Request {
  return new Request(new URL(path, origin).toString());
}

function postRequest(origin: string, path: string, body: unknown): Request {
  return new Request(new URL(path, origin).toString(), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function readBodyUpTo(req: Request, maxBytes: number): Promise<string> {
  const contentLength = req.headers.get("content-length")?.trim();
  if (contentLength && /^\d+$/.test(contentLength) && Number(contentLength) > maxBytes) {
    throw new Error("body too large");
  }
  const text = await req.text();
  if (text.length > maxBytes) throw new Error("body too large");
  return text;
}
