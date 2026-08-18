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
  /// Null for an anonymous caller, which the discovery methods allow.
  auth: AuthContext | null;
  ctx: ExecutionContext;
  origin: string;
  /// What the client says it speaks, from the MCP-Protocol-Version header or
  /// an initialize request. Decides whether results carry 2026-07-28 fields.
  protocolVersion: string;
}

/// A tool always runs with a credential; `handleMcp` refuses `tools/call`
/// without one before dispatch ever reaches here.
interface AuthedToolContext extends Omit<ToolContext, "auth"> {
  auth: AuthContext;
}

interface McpTool {
  name: string;
  title: string;
  description: string;
  schema: z.ZodType;
  scope: ApiScope;
  readOnly: boolean;
  invoke(args: Record<string, unknown>, tools: AuthedToolContext): Promise<Response>;
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

  // Authentication is per-method, not per-request.
  //
  // ChatGPT fetches the tool list with no Authorization header at all — both
  // from the connector settings and before it will offer the tools in a chat —
  // and a 401 there leaves it with no tools to call, which is what "Talked to
  // App" with nothing exposed looks like. Requiring a credential to *read the
  // menu* also buys nothing: the list is generated from static schemas, is byte
  // for byte identical for every tenant, and describes exactly what /llms.md
  // already publishes to anyone who asks.
  //
  // So an anonymous caller may discover; only `tools/call` needs a credential,
  // and that is where the 401 challenge still fires to start the OAuth flow.
  // A credential that is *present but bad* is always an error — ignoring it and
  // serving anonymously would turn a broken token into silent degradation.
  let auth: AuthContext | null = null;
  if (req.headers.has("authorization")) {
    try {
      auth = await requireAuth(req, env);
    } catch (err) {
      if (err instanceof AuthRateLimitError) {
        return json({ error: err.message }, 429, { "retry-after": "60" });
      }
      if (!(err instanceof AuthError)) throw err;
      console.warn("mcp request rejected", {
        userAgent: req.headers.get("user-agent") ?? "(none)",
        hasAuthorizationHeader: true,
        reason: err.message,
      });
      return mcpUnauthorized(req, err.message);
    }
  }

  let body: string;
  try {
    body = await readBodyUpTo(req, RequestBodyLimits.mcpRpc);
  } catch {
    return json(errorResponse(null, JSON_RPC_PARSE_ERROR, "request body is too large"), 413);
  }

  // ChatGPT opens with `POST /mcp` carrying content-length 0, content-type
  // application/octet-stream and no Authorization header — a reachability
  // probe, not a message. There is no JSON-RPC request in it to answer, to
  // authenticate, or to fail on, and 202 is what the spec prescribes for a POST
  // the server has nothing to respond to. It previously drew a 401, which reads
  // as "authenticate first" to a client holding no credential at that point in
  // its flow, sending it back around discovery without ever asking for the tool
  // list.
  if (body.trim() === "") return new Response(null, { status: 202 });

  let payload: unknown;
  try {
    payload = JSON.parse(body);
  } catch {
    console.warn("mcp body rejected", {
      userAgent: req.headers.get("user-agent") ?? "(none)",
      contentType: req.headers.get("content-type") ?? "(none)",
      contentLength: req.headers.get("content-length") ?? "(none)",
    });
    // An anonymous caller gets the challenge rather than a bare parse error:
    // it may simply not know yet that this endpoint wants a credential, and a
    // 400 gives it nothing to act on.
    if (!auth) return mcpUnauthorized(req, "authentication required");
    return json(errorResponse(null, JSON_RPC_PARSE_ERROR, "invalid JSON body"), 400);
  }

  if (!auth && needsCredential(payload)) {
    console.warn("mcp request rejected", {
      userAgent: req.headers.get("user-agent") ?? "(none)",
      hasAuthorizationHeader: false,
      reason: "tools/call requires a credential",
    });
    return mcpUnauthorized(req, "missing or malformed Authorization header");
  }

  const origin = new URL(req.url).origin;
  const tools: ToolContext = {
    env,
    auth,
    ctx,
    origin,
    protocolVersion: declaredProtocolVersion(req, payload),
  };

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
  const ok = (result: Record<string, unknown>) =>
    successResponse(id, result, tools.protocolVersion);

  switch (request.method) {
    // Pre-2026-07-28 handshake. Answered for compatibility; nothing is stored.
    case "initialize":
      return ok({
        protocolVersion: negotiatedProtocolVersion(request.params),
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        instructions:
          "Publish project state to the operator's iOS widgets and Live Activities. Call "
          + "get_integration_guide first to learn the card templates and their fields.",
      });
    // 2026-07-28 replacement for the handshake.
    case "server/discover":
      return ok({
        protocolVersion: LATEST_PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
    case "notifications/initialized":
    case "notifications/cancelled":
      return null;
    case "ping":
      return isNotification ? null : ok({});
    // Answered with empty lists rather than -32601. `initialize` advertises only
    // `tools`, so a client that respects capabilities never asks — but clients
    // probe anyway, and a JSON-RPC error reads as a broken server where "there
    // are none of those here" is both true and harmless. Cheap interop
    // insurance on a method that cannot do anything.
    case "resources/list":
      return ok(emptyList("resources"));
    case "resources/templates/list":
      return ok(emptyList("resourceTemplates"));
    case "prompts/list":
      return ok(emptyList("prompts"));
    case "tools/list":
      return ok({
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
  const ok = (result: Record<string, unknown>) =>
    successResponse(id, result, tools.protocolVersion);
  const call = (params ?? {}) as { name?: unknown; arguments?: unknown };
  if (typeof call.name !== "string") {
    return errorResponse(id, JSON_RPC_INVALID_PARAMS, "params.name is required");
  }
  const tool = TOOLS.find((candidate) => candidate.name === call.name);
  if (!tool) {
    return errorResponse(id, JSON_RPC_INVALID_PARAMS, `unknown tool '${call.name}'`);
  }
  // Belt and braces: the transport already refused an anonymous tools/call.
  if (!tools.auth) {
    return errorResponse(id, JSON_RPC_INVALID_REQUEST, "authentication required");
  }
  const authed: AuthedToolContext = { ...tools, auth: tools.auth };
  const args = (call.arguments ?? {}) as Record<string, unknown>;
  if (typeof args !== "object" || Array.isArray(args)) {
    return errorResponse(id, JSON_RPC_INVALID_PARAMS, "params.arguments must be an object");
  }

  // A scope failure is a protocol-level error, not a tool result: the model
  // cannot fix it by trying different arguments, and the operator has to issue
  // a different credential.
  if (!hasScope(authed.auth, tool.scope)) {
    return errorResponse(id, JSON_RPC_INVALID_REQUEST, `API scope '${tool.scope}' required`);
  }

  // Validated here as well as inside the handler so an argument mistake comes
  // back as a tool error the model can act on, rather than as a bare 400.
  const parsed = tool.schema.safeParse(args);
  if (!parsed.success) {
    return ok(toolError(`validation failed: ${parsed.error.message}`));
  }

  let response: Response;
  try {
    response = await tool.invoke(args, authed);
  } catch (err) {
    console.error("mcp tool failed", { tool: tool.name, error: String(err) });
    return errorResponse(id, JSON_RPC_INTERNAL_ERROR, "internal error");
  }

  const contentType = response.headers.get("content-type") ?? "";
  const text = await response.text();
  if (!response.ok) {
    return ok(toolError(text || `request failed with ${response.status}`));
  }
  if (!contentType.includes("application/json")) {
    return ok({ content: [{ type: "text", text }] });
  }
  let structured: unknown;
  try {
    structured = JSON.parse(text);
  } catch {
    return ok({ content: [{ type: "text", text }] });
  }
  return ok({
    content: [{ type: "text", text }],
    structuredContent: structured,
  });
}

function emptyList(key: string): Record<string, unknown> {
  return { [key]: [], ttlMs: TOOL_LIST_TTL_MS, cacheScope: "public" };
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

function successResponse(
  id: string | number | null,
  result: Record<string, unknown>,
  protocolVersion: string,
) {
  // `resultType` arrived in 2026-07-28. Sending it to a client that negotiated
  // an earlier revision means putting a field in the response that the schema
  // it validates against does not define — harmless to a lenient client, fatal
  // to a strict one, and gaining nothing either way. Emit it only for clients
  // that speak the revision requiring it. This server never asks the client for
  // input mid-call, so every result it does emit is complete.
  const body = protocolVersion === LATEST_PROTOCOL_VERSION
    ? { resultType: "complete", ...result }
    : result;
  return { jsonrpc: "2.0", id, result: body };
}

/// Only running a tool needs a credential. Discovery does not.
function needsCredential(payload: unknown): boolean {
  const entries = Array.isArray(payload) ? payload : [payload];
  return entries.some((entry) => (entry as JsonRpcRequest | undefined)?.method === "tools/call");
}

/// The revision the client claims, from the transport header the 2026-07-28
/// revision defines or from an `initialize` still using the old handshake.
/// Absent both, assume a pre-2026 client, which is the safe assumption: it
/// means withholding a field rather than inventing one.
function declaredProtocolVersion(req: Request, payload: unknown): string {
  const header = req.headers.get("mcp-protocol-version")?.trim();
  if (header) return header;
  const entries = Array.isArray(payload) ? payload : [payload];
  for (const entry of entries) {
    const params = (entry as JsonRpcRequest | undefined)?.params as
      | { protocolVersion?: unknown }
      | undefined;
    if (typeof params?.protocolVersion === "string") return params.protocolVersion;
  }
  return "";
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
