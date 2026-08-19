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
import * as dashboard from "./dashboard";
import * as liveActivities from "./liveActivities";
import * as status from "./status";
import { json } from "./http";
import { llmsMarkdown } from "./generated/llmsDoc";
import { renderHostedLlmsMarkdown } from "./landing";
import { mcpConfigured, mcpUnauthorized } from "./mcpOAuth";
import { subscriptionGate, subscriptionRequiredMessage } from "./subscription";
import {
  BatchUpsertCardsSchema,
  DashboardCardInputSchema,
  DashboardCardSchema,
  EndLiveActivitySchema,
  LiveActivitySessionSchema,
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

// The guide an MCP client gets, which is not the guide a person writing code
// gets. A tool caller already has typed arguments with per-field descriptions,
// so most of docs/llms.md is dead weight in its context window: curl
// invocations for endpoints it addresses by name, the same publish written out
// in four languages, credential setup that OAuth already did, field limits the
// JSON Schema already states. What is left is what no schema can carry — which
// template fits which shape of data, and the rules a Live Activity enforces
// without reporting.
//
// Filtered from the one source document rather than written separately, so it
// cannot fall out of step with it.
export const MCP_GUIDE_SECTIONS = {
  essentials: [
    "Tap behavior",
    "Data model",
    "Choosing a template",
    "Publishing a card",
    "Live Activities",
    "Actions",
    "Rate limits",
    "Errors",
    "Don'ts",
  ],
  cards: ["Data model", "Choosing a template", "Publishing a card", "Don'ts"],
  "live-activities": ["Live Activities", "Errors", "Don'ts"],
  actions: ["Actions", "Errors"],
  everything: null,
} as const;

export type McpGuideSection = keyof typeof MCP_GUIDE_SECTIONS;

export function renderMcpGuide(section: McpGuideSection, baseURL: string): string {
  const wanted = MCP_GUIDE_SECTIONS[section];
  if (wanted === null) return renderHostedLlmsMarkdown(baseURL);
  return mcpGuidePreamble(section, baseURL) + stripShellExamples(selectSections(llmsMarkdown, wanted));
}

/// Says what was left out and how to get it back, so a caller that needs the
/// HTTP surface knows it exists rather than concluding it does not. The base
/// URL is here because it is the one thing from the credential section a tool
/// caller might still want — for the day it stops being a tool caller.
function mcpGuidePreamble(section: McpGuideSection, baseURL: string): string {
  return [
    `# 00Widget — ${section}`,
    "",
    "The publishing rules, trimmed for MCP clients: the tool schemas already",
    "carry every field and its limits, so what is left here is what they cannot",
    "say. Credential setup, curl invocations and the client snippets are gone;",
    'ask for `section: "everything"` to read the full public document.',
    "",
    `This deployment is \`00WIDGET_BASE_URL=${baseURL}\`, if you ever need to`,
    "call the HTTP API directly instead of through these tools.",
    "",
    "---",
    "",
  ].join("\n");
}

/// Keeps whole `##` sections by title, with every `###` under them.
///
/// Fenced blocks are tracked, because a `#` at the start of a line inside one
/// is a shell comment rather than a heading. The document is full of them
/// (`# → {"ok":true}`), and reading one as a heading silently truncates the
/// section it sits in and leaves the fence unbalanced for whatever runs next.
function selectSections(markdown: string, titles: readonly string[]): string {
  const wanted = new Set<string>(titles);
  const out: string[] = [];
  let keeping = false;
  let inFence = false;
  for (const line of markdown.split("\n")) {
    if (line.startsWith("```")) inFence = !inFence;
    else if (!inFence && line.startsWith("## ")) keeping = wanted.has(line.slice(3).trim());
    else if (!inFence && line.startsWith("# ")) keeping = false;
    if (keeping) out.push(line);
  }
  return out.join("\n").trim() + "\n";
}

/// Drops ```sh blocks. Each is a curl form of a call this client makes by tool
/// name, so it costs context and teaches the wrong interface. The ```json
/// blocks stay: those are payload shapes, which is exactly what the caller is
/// building.
function stripShellExamples(markdown: string): string {
  const out: string[] = [];
  let inShell = false;
  for (const line of markdown.split("\n")) {
    if (!inShell && /^```(sh|bash|shell)\b/.test(line)) {
      inShell = true;
      continue;
    }
    if (inShell) {
      if (line.startsWith("```")) inShell = false;
      continue;
    }
    out.push(line);
  }
  // Collapse the blank-line pairs the removals leave behind.
  return out.join("\n").replace(/\n{3,}/g, "\n\n");
}

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

const SERVER_INSTRUCTIONS =
  "Publish project state to the operator's iOS widgets and Live Activities. Call "
  + "get_integration_guide first to learn the card templates and their fields.";

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

// What each tool puts in `structuredContent`, which is the response its route
// already returns. Declaring it is not decoration: a tool that emits structured
// content is expected to say what shape it is, and a strict client validates
// against this. `get_integration_guide` deliberately has none — it answers with
// markdown, so there is no structured content to describe.
const ApnsResultSchema = z.object({
  status: z.number().describe("The HTTP status APNs answered with; 200 is delivered."),
  reason: z.string().optional().describe("APNs failure reason, when it failed."),
  apnsId: z.string().nullable().optional().describe("APNs' own id for the push."),
  retryAfterSeconds: z.number().optional(),
});

const CardOutput = z.object({ card: DashboardCardSchema });
const CardsOutput = z.object({
  cards: z.array(DashboardCardSchema),
  shared: z.array(DashboardCardSchema).optional().describe(
    "Cards other tenants have shared with this one. Only present when asked for.",
  ),
});
const OkOutput = z.object({ ok: z.boolean() });
const DashboardOutput = z.object({
  cards: z.array(DashboardCardSchema),
  activities: z.array(LiveActivitySessionSchema),
});
const ActivitiesOutput = z.object({ activities: z.array(LiveActivitySessionSchema) });
const StartActivityOutput = z.object({
  ok: z.boolean(),
  activityInstanceId: z.string().describe("The server's id for this exact activity."),
  restarted: z.boolean().describe(
    "True when an activity was already running under this id, so it was ended "
    + "and replaced rather than started fresh. The user saw one dismiss and "
    + "another animate in.",
  ),
  pending: z.boolean(),
  pushToStartAttempted: z.number().describe(
    "How many devices were sent the push that starts the activity. ZERO means "
    + "nobody will see this one, or anything else you publish: the operator has "
    + "no device registered, so tell them to open the 00Widget app and allow "
    + "notifications rather than continuing to publish.",
  ),
  apnsResults: z.array(ApnsResultSchema),
});
const UpdateActivityOutput = z.object({
  ok: z.boolean(),
  activityInstanceId: z.string(),
  apnsResult: ApnsResultSchema.nullable(),
  recipientResults: z.array(ApnsResultSchema),
  pendingUpdated: z.boolean().describe(
    "True when the new state was stored but no device holds a token for this "
    + "activity yet, so nothing was pushed.",
  ),
});
const EndActivityOutput = z.object({
  ok: z.boolean(),
  apnsResult: ApnsResultSchema.nullable(),
  recipientResults: z.array(ApnsResultSchema),
});

interface McpTool {
  name: string;
  title: string;
  description: string;
  schema: z.ZodType;
  /// The shape of `structuredContent`. Omitted only by tools that do not
  /// answer with JSON.
  outputSchema?: z.ZodType;
  scope: ApiScope;
  readOnly: boolean;
  /// Irreversible from the caller's side, in a way a person would want to
  /// confirm. Not merely "writes something" — see the note on TOOL_DESCRIPTORS.
  destructive: boolean;
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
    outputSchema: CardsOutput,
    scope: "read",
    readOnly: true,
    destructive: false,
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
    description: "Read one published card by its stable id. Returns `{ card }`, the same envelope every other read on this API uses.",
    schema: z.object({ id: z.string().min(1).describe("The card's stable id.") }),
    outputSchema: CardOutput,
    scope: "read",
    readOnly: true,
    destructive: false,
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
    outputSchema: CardOutput,
    scope: "publish",
    readOnly: false,
    destructive: false,
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
    outputSchema: z.object({ cards: z.array(DashboardCardSchema) }),
    scope: "publish",
    readOnly: false,
    destructive: false,
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
    outputSchema: OkOutput,
    scope: "publish",
    readOnly: false,
    destructive: true,
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
    title: "List Live Activities",
    description:
      "The Live Activities this tenant currently has running, with their content state. Pass "
      + "includeEnded to also get the ones that finished in the last day — which is how to check "
      + "whether an end actually landed, or to find an activity whose externalActivityId you lost.",
    schema: z.object({
      includeEnded: z
        .boolean()
        .optional()
        .describe("Also return activities that ended within the last 24 hours."),
    }),
    outputSchema: ActivitiesOutput.extend({
      ended: z.array(z.object({
        activityInstanceId: z.string(),
        externalActivityId: z.string(),
        kind: z.string(),
        title: z.string(),
        finalState: z.string().optional(),
        finalSubtitle: z.string().optional(),
        startedAt: z.string().optional(),
        endedAt: z.string(),
      })).optional().describe("Present only when includeEnded was set."),
    }),
    scope: "read",
    readOnly: true,
    destructive: false,
    invoke: (args, tools) =>
      liveActivities.activeActivities(
        getRequest(
          tools.origin,
          args.includeEnded ? "/v1/live-activities?include=ended" : "/v1/live-activities",
        ),
        tools.env,
        tools.auth,
      ),
  },
  {
    name: "start_live_activity",
    title: "Start a Live Activity",
    description:
      "Start a Live Activity on the Lock Screen and Dynamic Island. Use this only for something "
      + "time-bounded with a clear end — a build, a wash cycle, a charge, a delivery — and always end "
      + "it. `title`, `kind` and `deepLink` are frozen when it starts and cannot be changed by an "
      + "update, so anything that must move belongs in the content state fields. Calling this again "
      + "with an id that is already running restarts it, which is visible to the user.",
    schema: StartLiveActivitySchema,
    outputSchema: StartActivityOutput,
    scope: "publish",
    readOnly: false,
    destructive: false,
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
    outputSchema: UpdateActivityOutput,
    scope: "publish",
    readOnly: false,
    destructive: false,
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
    description:
      "End a running Live Activity with a final frame. Always end what you start. This cannot be "
      + "undone: an ended activity cannot be resumed, only replaced by starting a new one, which "
      + "the user sees as the old one dismissing and a new one animating in.",
    schema: EndLiveActivitySchema,
    outputSchema: EndActivityOutput,
    scope: "publish",
    readOnly: false,
    destructive: true,
    invoke: (args, tools) =>
      liveActivities.endLiveActivity(
        postRequest(tools.origin, "/v1/live-activities/end", args),
        tools.env,
        tools.auth,
      ),
  },
  {
    name: "get_dashboard",
    title: "Read everything at once",
    description:
      "Every published card and every running Live Activity in one call. Prefer it over list_cards "
      + "plus list_live_activities when you want the whole picture — it is one request instead of two "
      + "and the two halves are read together.",
    schema: NoArguments,
    outputSchema: DashboardOutput,
    scope: "read",
    readOnly: true,
    destructive: false,
    invoke: (_args, tools) =>
      dashboard.getDashboard(getRequest(tools.origin, "/v1/dashboard"), tools.env, tools.auth),
  },
  {
    name: "get_status",
    title: "Check what this connection can reach",
    description:
      "Whether anything will actually see what you publish, what this credential may do, how much "
      + "rate budget is left, and what this deployment has enabled. Worth one call before publishing "
      + "for the first time: if `delivery.canPushWidgets` is false, nothing you publish will be seen "
      + "by anyone, and the operator needs to install the app and allow notifications rather than "
      + "you trying again.",
    schema: NoArguments,
    // Shaped by hand rather than from a zod schema: the route builds its
    // response literally, and inventing a schema module for one read would put
    // the description further from the thing it describes.
    outputSchema: z.object({
      account: z.object({
        tenantId: z.string(),
        credentialKind: z.string(),
        scopes: z.array(z.string()).describe("What this credential may do."),
        credentialExpiresAt: z.string(),
      }),
      delivery: z.object({
        devices: z.number(),
        widgetPushTokens: z.number(),
        liveActivityStartTokens: z.number(),
        canPushWidgets: z.boolean().describe(
          "False means no device can receive a widget reload: what you publish is stored and seen "
          + "by nobody.",
        ),
        canStartLiveActivities: z.boolean().describe(
          "False means a Live Activity cannot appear on any device.",
        ),
        widgetReloadIntervalSeconds: z.number().describe(
          "A Home Screen widget redraws at most this often per account. Publishes in between are "
          + "stored immediately and coalesced into the next one.",
        ),
        secondsUntilNextWidgetReload: z.number(),
      }),
      published: z.object({ cards: z.number(), liveActivities: z.number() }),
      features: z.object({ sharing: z.boolean(), mcp: z.boolean() }),
      subscription: z.object({
        enabled: z.boolean(),
        required: z.boolean().describe("Whether writes are refused without an active subscription."),
        state: z.unknown().optional(),
      }),
      rateLimits: z.array(z.object({
        label: z.string(),
        limit: z.number(),
        remaining: z.number(),
        resetAt: z.string(),
      })).describe("Only windows this account has touched; anything absent has its full allowance."),
    }),
    scope: "read",
    readOnly: true,
    destructive: false,
    invoke: (_args, tools) =>
      status.getStatus(getRequest(tools.origin, "/v1/status"), tools.env, tools.auth),
  },
  {
    name: "get_integration_guide",
    title: "Read the 00Widget integration guide",
    description:
      "The rules no argument schema can carry: which template fits which shape of data, what a "
      + "Live Activity freezes at start, and what publishing etiquette costs you if you ignore it. "
      + "Read it before publishing for the first time. Narrow it with `section` when you already "
      + "know which half you need.",
    schema: z.object({
      section: z
        .enum(Object.keys(MCP_GUIDE_SECTIONS) as [McpGuideSection, ...McpGuideSection[]])
        .default("essentials")
        .describe(
          "Which part to return. `essentials` (default) is everything a publisher needs; `cards`, "
          + "`live-activities` and `actions` narrow it further; `everything` is the full public "
          + "document, including the HTTP and code-level material an MCP client has no use for.",
        ),
    }),
    scope: "read",
    readOnly: true,
    destructive: false,
    invoke: async (args, tools) =>
      new Response(
        renderMcpGuide((args.section as McpGuideSection) ?? "essentials", tools.origin),
        { headers: { "content-type": "text/markdown; charset=utf-8" } },
      ),
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
  // Only when there is one: declaring an outputSchema is a promise that the
  // tool returns matching structuredContent, and the guide tool answers with
  // markdown.
  ...(tool.outputSchema ? { outputSchema: toolOutputSchema(tool.outputSchema) } : {}),
  annotations: {
    title: tool.title,
    readOnlyHint: tool.readOnly,
    // `destructiveHint` drives whether a client asks a person before going
    // ahead, so it marks what is irreversible rather than merely what writes.
    // Deleting a card and ending a Live Activity qualify: the content is gone,
    // and an ended activity cannot be resumed. Publishing does not, even though
    // an upsert replaces a card wholesale rather than merging into it — that
    // replacement is the entire point of the integration, and flagging it would
    // put a confirmation in front of every routine publish and teach people to
    // click through the two that matter.
    destructiveHint: tool.destructive,
    // Every tool here is idempotent: republishing the same card, re-ending an
    // ended activity, or deleting an absent one all converge on the same state.
    idempotentHint: true,
    // Nothing reaches outside the operator's own 00Widget account.
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

/// `io: "output"` rather than "input": a field carrying a zod default is
/// optional to send and always present in what comes back, and the two schemas
/// have to say so differently.
function toolOutputSchema(schema: z.ZodType): Record<string, unknown> {
  const converted = z.toJSONSchema(schema, { io: "output" }) as Record<string, unknown>;
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

  // Every JSON-RPC message needs a credential. The one thing that does not is
  // the empty probe below, which carries no message at all.
  //
  // ChatGPT authenticates server/discover, tools/list and tools/call alike, so
  // there is nothing to gain by opening the tool list up — an earlier version
  // did, on the mistaken reading that the unauthenticated requests in the logs
  // were tool listings. They were the probe.
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

  if (!auth) {
    console.warn("mcp request rejected", {
      userAgent: req.headers.get("user-agent") ?? "(none)",
      hasAuthorizationHeader: false,
      reason: "missing or malformed Authorization header",
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
        instructions: SERVER_INSTRUCTIONS,
      });
    // 2026-07-28 replacement for the handshake. The shape is exact and worth
    // keeping that way: `supportedVersions` (a list, not the single
    // `protocolVersion` the legacy handshake returns), capabilities, and
    // serverInfo under its namespaced `_meta` key rather than at the top level.
    // A client that cannot parse this learns nothing about the server and has
    // no reason to go on and ask for the tools.
    case "server/discover":
      return ok({
        supportedVersions: [...SUPPORTED_PROTOCOL_VERSIONS],
        capabilities: { tools: {} },
        instructions: SERVER_INSTRUCTIONS,
        ttlMs: TOOL_LIST_TTL_MS,
        cacheScope: "public",
        _meta: {
          "io.modelcontextprotocol/serverInfo": {
            name: SERVER_NAME,
            version: SERVER_VERSION,
          },
        },
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

  // A lapsed subscription is a tool error rather than a protocol error, unlike
  // the scope failure above. Both are for the operator to fix, but this one is
  // fixed by renewing rather than by reissuing a credential, and a tool error
  // is what reaches the model's context — so the agent can tell its human what
  // happened instead of the connector merely looking broken.
  const lapsed = await subscriptionGate(authed.env, authed.auth, tool.scope);
  if (lapsed) {
    return ok(toolError(subscriptionRequiredMessage(lapsed), {
      status: 402,
      code: "subscription_required",
    }));
  }

  // Validated here as well as inside the handler so an argument mistake comes
  // back as a tool error the model can act on, rather than as a bare 400.
  const parsed = tool.schema.safeParse(args);
  if (!parsed.success) {
    // Never reaches the route, so it has no status of its own — but it is the
    // same 400 the route would have answered with, and equally unretryable.
    return ok(toolError(`validation failed: ${parsed.error.message}`, { status: 400 }));
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
    return ok(toolFailure(response, text));
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

/// Every tool error carries the same structured detail, whichever layer
/// produced it — a schema rejection here, a lapsed subscription, or a status
/// from the route underneath. A model should not have to tell them apart by
/// reading prose to find out whether trying again could possibly work.
function toolError(message: string, detail: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    content: [{ type: "text", text: message }],
    structuredContent: { error: message, retryable: false, ...detail },
    isError: true,
  };
}

/// A failed route response, turned into a tool error the model can act on
/// rather than only read.
///
/// The body used to be the whole of it, which meant the status code and every
/// header were dropped on the floor. A `429` arrived as a sentence with the
/// retry delay buried in JSON inside it, and nothing distinguished "your card
/// was rejected" from "the far end is down" except wording. Structured
/// alongside the text, a model can branch on the number.
function toolFailure(response: Response, text: string): Record<string, unknown> {
  const detail: Record<string, unknown> = { status: response.status };

  const retryAfter = Number(response.headers.get("retry-after"));
  if (Number.isFinite(retryAfter) && retryAfter > 0) detail.retryAfterSeconds = retryAfter;

  // The route's own error body, when it sent one. Its fields — `error`, `code`,
  // `retryAfter`, `subscription` — are what the REST docs tell a caller to read.
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = undefined;
  }
  if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
    Object.assign(detail, parsed);
  }

  // `retryable` is the one judgement the transport can make for the model, and
  // the one it most often gets wrong on its own: a 4xx that is not 429 will
  // fail again identically, and retrying it just burns the budget.
  detail.retryable = response.status === 429 || response.status >= 500;

  // Carried in `structuredContent` even on tools that declare an
  // `outputSchema`, which this deliberately does not match: an error result is
  // not the tool's output, and a client validating it against the success shape
  // would have no way to let any tool report a failure at all. `isError` is
  // what says which of the two this is.
  return toolError(text || `request failed with ${response.status}`, detail);
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
      | { protocolVersion?: unknown; _meta?: Record<string, unknown> }
      | undefined;
    // Modern revisions put it in namespaced request metadata; the legacy
    // handshake put it in params directly.
    const fromMeta = params?._meta?.["io.modelcontextprotocol/protocolVersion"];
    if (typeof fromMeta === "string") return fromMeta;
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
