# MCP Apps support for the 00Widget MCP server

Spec written 2026-09-24, revised 2026-09-25. Target: add optional focused-card
and dashboard views without changing the behavior or wire contract of the MCP
endpoint currently under OpenAI review.

## Decision

Add two new, read-only render tools linked to one shared, versioned MCP Apps
resource:

- `render_card { id }` is the primary visual tool. It renders the one 00Widget
  card the user asked about.
- `render_dashboard {}` is the secondary overview tool. It renders all cards
  and running Live Activities.

The first preview candidate uses
`ui://00widget/preview/v1-preview.1.html`; the resource selects its focused-card
or dashboard layout from the structured-result envelope.

Develop and deploy them first on `https://api.00widget.com/mcp-preview`, a
separate Developer Mode connection behind `MCP_PREVIEW_ENABLED`. The submitted
`https://api.00widget.com/mcp` endpoint must keep its current initialization,
tool, prompt, and resource responses exactly unchanged while review is active.
After the preview passes its evaluation set and the current review completes,
promote the preview contract to `/mcp` in one deployment.

Keep every existing tool headless. In particular, do **not** attach a template
to `get_card`, `get_dashboard`, card writes, or Live Activity writes. A model
can continue using the current tools exactly as it does today; it calls a
render tool only when the user asks to see the result or a visual would help.

The app is a standards-first, dependency-free HTML view. It receives either
the `{ card }` envelope that `get_card` already returns or the
`{ cards, activities }` envelope that `get_dashboard` already returns. Its
card and Live Activity rendering comes from an extracted version of the
browser renderer currently embedded in `server/src/guestPage.ts`.

This is an **interactive-decoupled** MCP App:

- Existing data and mutation tools remain independently useful to models and
  non-UI MCP clients.
- `render_card` is the preferred model-visible render tool for a named widget;
  `render_dashboard` is reserved for overview intent.
- The mounted view can refresh through the matching existing read-only tool,
  `get_card` or `get_dashboard`, without remounting itself.
- The first release is otherwise display-only. It does not run card actions,
  publish cards, or mutate Live Activities.

## Goals

1. Render one requested card inline, or the operator's complete cards and
   running Live Activities when they explicitly ask for an overview.
2. Preserve all existing tool names, input schemas, output schemas, content,
   authentication, authorization, and side effects.
3. Reuse one browser rendering implementation for guest links and MCP Apps so
   new card fields cannot silently diverge between two web renderers.
4. Work as an ordinary text/structured-data MCP tool in hosts that do not
   support MCP Apps.
5. Require no browser access to the 00Widget API and expose no bearer token to
   the iframe.

## Non-goals

- Replacing the iOS, widget, Watch, tvOS, or Horizon renderers.
- Making every MCP tool open a component.
- Running card actions from the component. The MCP credential intentionally
  has no action-execution tool, and destructive confirmation belongs in the
  native app for now.
- Auto-polling. The initial version refreshes only when the person asks it to.
- Changing the draft currently under review. A dedicated `_meta.ui.domain`,
  review assets, updated test cases, and release notes belong to the later
  promotion/submission milestone.
- Pixel-identical SwiftUI rendering. The existing guest renderer is the web
  semantic equivalent, not a screenshot of the native widget.

## Existing implementation to build on

The MCP server is hand-written in `server/src/mcp.ts`, rather than built on an
MCP server SDK. This is a good fit for the Worker and should not change merely
to add UI.

Useful existing boundaries:

- `CardOutput` already describes `{ card }`, and `get_card` already resolves a
  stable card id without a new query.
- `DashboardOutput` already describes `{ cards, activities }`.
- `get_dashboard` already reads both halves together through
  `dashboard.getDashboard`, so the render path does not need a new storage
  query or REST endpoint.
- Every successful JSON tool result already carries both model-readable
  `content` and machine-readable `structuredContent`.
- Published output schemas are intentionally open and unbounded so additive
  server changes do not break clients holding a cached `tools/list`.
- `resources/list` and `resources/templates/list` already return successful
  empty lists, giving the new resource support an obvious insertion point.
- `server/src/guestPage.ts` already renders summary, progress, list, history,
  breakdown, briefing, chart, range, multi-series, semantic, timeline, and Live
  Activity states in a self-contained HTML/CSS/JS page.
- Webhook ids and action payloads are write-only and stripped before card state
  is returned. The dashboard result therefore contains no private webhook
  payload to leak to either the model or the component.

The reusable part of `guestPage.ts` is presently trapped inside one large
`GUEST_SCRIPT` IIFE. Extraction is part of this work, not an optional cleanup.
Copying it would create a fourth renderer whose missing fields fail silently;
the existing guest-page tests document that this has already happened.

## Endpoint channels and versioning

### Stable channel: `/mcp`

`/mcp` is the endpoint OpenAI has already scanned and is reviewing. Until that
review completes, it must continue using a `stable` MCP surface:

- identical `initialize` and `server/discover` results;
- identical tool descriptors and ordering;
- the current empty `resources/list`, `resources/templates/list`, and prompt
  lists;
- no render tools and no UI metadata on existing tools.

This is stronger than ordinary additive compatibility because it protects the
submitted metadata snapshot from drift during review.

### Preview channel: `/mcp-preview`

Add a second route served by the same Worker and OAuth authorization server:

```text
POST https://api.00widget.com/mcp-preview
GET  https://api.00widget.com/mcp-preview.json
GET  https://api.00widget.com/.well-known/oauth-protected-resource/mcp-preview
```

The route is available only when `MCP_PREVIEW_ENABLED=true`; otherwise every
preview URL returns 404. Connect it separately in ChatGPT Developer Mode as
`00Widget Preview`. It uses the same tenant authentication, `read` scope, and
stored dashboard data as `/mcp`, so it tests real rendering without a second
account or database. It is a release channel, not a security boundary.

The preview 401 challenge must advertise the path-specific protected-resource
metadata URL. That document declares its resource as
`https://api.00widget.com/mcp-preview`; the existing bare document continues to
declare `/mcp`. Both may use the same authorization, registration, and token
endpoints. This keeps Sign in with Apple on the already configured hostname.

Do not call the route `/mcp/v2` or `/mcp-v2`. MCP server `version` is
informational, not feature negotiation, and a permanent v2 URL would imply a
second public API contract. The durable public endpoint remains `/mcp`.

Implement the channel as an explicit `McpChannel = "stable" | "preview"`
argument passed from routing through discovery, resource dispatch, and tool
dispatch. Do not infer it from a header, cookie, query parameter, tenant, or
client identity. Tests must be able to construct both channels directly.

This gives metadata isolation, not process isolation: both paths ship in one
Worker bundle. The stable golden tests are therefore mandatory. If a later
preview needs risky storage, authentication, or transport changes, use a
separate Worker and hostname instead, with its protected-resource metadata
pointing at the production authorization server. That is stronger isolation
but adds DNS/TLS, bindings, secrets, and deployment drift that this read-only UI
addition does not justify.

Rejected switches:

- `?preview=1` or a request header: too easy for a host refresh, OAuth
  discovery, cache, or manual test to omit, producing the wrong descriptor set.
- Tenant or credential allowlisting on `/mcp`: the submission scanner and
  reviewer may authenticate differently, so the reviewed endpoint would no
  longer have one deterministic contract.
- `/mcp/v2`: suggests permanent protocol/API versioning when this is a
  temporary release channel.

### Promotion

Promotion changes only which contract `/mcp` selects. After the current review
completes, point the stable channel at the tested Apps-enabled descriptor set.
Keep `/mcp-preview` for the next candidate or disable it until another preview
exists. Never promote by redirecting `/mcp` to `/mcp-preview`: OAuth resource
identity and clients' configured endpoint should remain stable.

## Preview MCP contract

### New primary tool: `render_card`

Descriptor:

```json
{
  "name": "render_card",
  "title": "Show one 00Widget card",
  "description": "Use this when the user wants to see one specific 00Widget card or widget. Pass its stable card id. Use render_dashboard only when they ask for an overview of everything.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": { "type": "string", "minLength": 1 }
    },
    "required": ["id"],
    "additionalProperties": false
  },
  "outputSchema": "the existing open CardOutput schema",
  "annotations": {
    "title": "Show one 00Widget card",
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": false
  },
  "_meta": {
    "ui": {
      "resourceUri": "ui://00widget/preview/v1-preview.1.html",
      "visibility": ["model", "app"]
    },
    "openai/outputTemplate": "ui://00widget/preview/v1-preview.1.html",
    "openai/toolInvocation/invoking": "Loading card…",
    "openai/toolInvocation/invoked": "Card ready"
  }
}
```

The handler requires `read`, reuses the existing `get_card` adapter, returns
the unchanged `{ card }` body as `structuredContent`, and uses a concise text
fallback such as `Card: Solar — 4.2 kW.` Missing ids have the same not-found
semantics as `get_card`.

### New overview tool: `render_dashboard`

Descriptor:

```json
{
  "name": "render_dashboard",
  "title": "Show the 00Widget dashboard",
  "description": "Use this when the user wants to see their 00Widget cards and running Live Activities as a visual dashboard. This reads the current snapshot itself; do not call get_dashboard first just to prepare it.",
  "inputSchema": {
    "type": "object",
    "properties": {},
    "additionalProperties": false
  },
  "outputSchema": "the existing open DashboardOutput schema",
  "annotations": {
    "title": "Show the 00Widget dashboard",
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": false
  },
  "_meta": {
    "ui": {
      "resourceUri": "ui://00widget/preview/v1-preview.1.html",
      "visibility": ["model", "app"]
    },
    "openai/outputTemplate": "ui://00widget/preview/v1-preview.1.html",
    "openai/toolInvocation/invoking": "Loading dashboard…",
    "openai/toolInvocation/invoked": "Dashboard ready"
  }
}
```

The standard `_meta.ui.resourceUri` is authoritative. The
`openai/outputTemplate` key is only the ChatGPT compatibility alias.

Handler behavior:

1. Require the existing `read` scope.
2. Call `dashboard.getDashboard` through the same adapter used by
   `get_dashboard`.
3. Return its body unchanged as `structuredContent`.
4. Return concise text such as `Dashboard: 6 cards and 2 running Live
   Activities.` rather than serializing the complete JSON into `content`.

The last point needs a small optional result formatter on `McpTool`. Existing
tools keep today's raw-response text behavior; only the two render tools use
the formatter. A non-UI client therefore still receives a useful text fallback
and the complete structured snapshot.

Do not add input filters in v1. A full authoritative snapshot is cheap, avoids
large model-authored card objects as tool input, and lets the mounted view
filter locally. If dashboard size becomes a real problem, add optional filters
later; optional input fields are an additive change.

### New resource

Use one exact, versioned URI for both render tools:

```text
ui://00widget/preview/v1-preview.1.html
```

`resources/list` returns:

```json
{
  "resources": [
    {
      "uri": "ui://00widget/preview/v1-preview.1.html",
      "name": "00Widget preview",
      "description": "One focused card or the complete dashboard, rendered read-only from the calling tool's result.",
      "mimeType": "text/html;profile=mcp-app"
    }
  ]
}
```

`resources/read` with that URI returns one text resource:

```json
{
  "contents": [
    {
      "uri": "ui://00widget/preview/v1-preview.1.html",
      "mimeType": "text/html;profile=mcp-app",
      "text": "<!doctype html>…",
      "_meta": {
        "ui": {
          "prefersBorder": false,
          "csp": {
            "connectDomains": [],
            "resourceDomains": []
          },
          "domain": "https://api.00widget.com"
        },
        "openai/ui": {
          "availableDisplayModes": ["inline", "fullscreen"]
        },
        "openai/widgetDescription": "A visual 00Widget card or dashboard using the state returned by the tool.",
        "openai/widgetPrefersBorder": false,
        "openai/widgetDomain": "https://api.00widget.com",
        "openai/widgetCSP": {
          "connect_domains": [],
          "resource_domains": []
        }
      }
    }
  ]
}
```

Notes:

- The page is a complete HTML5 document with inline CSS and JS.
- It needs no external network, asset, frame, device, or clipboard permission.
- `prefersBorder` is false because each 00Widget card draws its own boundary.
- Declare the deployment origin in `_meta.ui.domain` and the ChatGPT
  `openai/widgetDomain` compatibility alias. This deployment is the component's
  dedicated origin; the HTML itself remains inline and self-contained.
- `resources/templates/list` remains empty because this is one exact resource,
  not a URI template.
- An unknown URI returns a normal MCP resource-not-found error; it must never
  fall through to the tool dispatcher or return an empty successful resource.

On the preview channel, advertise a `resources` capability from both the legacy
`initialize` response and current `server/discover` response. Do not set
`subscribe` or `listChanged`: the resource is immutable at a given URI. The
stable channel keeps its current discovery response until promotion.

### Resource versioning

Treat the URI as a cache key. Compatible CSS fixes and renderer bug fixes may
remain on `v1`; any change to the bridge contract, expected structured data,
or document boot sequence publishes `v2.html` and updates both render tools in
the same deployment.

While iterating rapidly in preview, use an explicit candidate URI such as
`ui://00widget/preview/v1-preview.3.html` and bump the candidate suffix whenever
cached HTML would hide the change. Before promotion, freeze the accepted bytes
at `ui://00widget/preview/v1.html` and run the full evaluation set against that
exact URI. Resource versions and endpoint channels solve different problems:
the URI invalidates cached UI; `/mcp-preview` isolates unreviewed metadata.

The existing one-hour `tools/list` cache means a deployment can temporarily
serve clients holding the prior descriptor. Keep every previously published
resource URI readable for at least one tool-list TTL plus normal clock skew;
prefer retaining old resource handlers indefinitely because the HTML is small.

## View runtime

### Shared renderer extraction

Create `server/src/webPreview.ts` with two exports:

- `WEB_PREVIEW_STYLES`: the renderer styles and host-variable fallbacks.
- `WEB_PREVIEW_RUNTIME`: standalone browser JavaScript that installs a small
  `window.ZeroZeroPreview` API:

```ts
interface ZeroZeroPreview {
  renderCard(card: unknown): string;
  renderActivity(activity: unknown): string;
  renderDashboard(snapshot: { cards?: unknown[]; activities?: unknown[] }): string;
}
```

The implementation stays suitable for direct embedding in Worker-generated
HTML: no imports, bundler, remote assets, or runtime package.

Refactor `guestPage.ts` into an adapter around that shared runtime:

1. Read the fragment token.
2. Fetch `/v1/guest/resource` as it does today.
3. Call `renderCard` or `renderActivity`.
4. Add guest-only expiry copy and the `Get 00Widget` CTA.

The resulting guest page must preserve its byte-level security properties:
token only in the fragment, same-origin fetch, hashed inline script/style CSP,
no referrer, and no interpolation of untrusted text into attributes or class
names.

Create `server/src/mcpApp.ts` as the second adapter. It builds the complete
MCP App HTML from the same styles/runtime plus a small postMessage bridge.

### Standards-first bridge

Do not make `window.openai` the primary transport. The view uses JSON-RPC over
`postMessage`:

1. Send `ui/initialize` with protocol `2026-01-26`, app name/version, and
   `availableDisplayModes: ["inline", "fullscreen"]`.
2. After the response, send `ui/notifications/initialized`.
3. Render the initial snapshot from
   `ui/notifications/tool-result.params.structuredContent`.
   `{ card }` selects focused-card mode; `{ cards, activities }` selects
   dashboard mode. Any other envelope shows a bounded unsupported-result error.
4. Listen for `ui/notifications/host-context-changed` and update theme, locale,
   timezone, dimensions, and host CSS variables.
5. Use a `ResizeObserver` to send `ui/notifications/size-changed` after the
   dashboard changes size.
6. The Refresh button sends `tools/call` for `get_card` with the rendered
   card's id in focused mode, or `get_dashboard` in dashboard mode, and renders
   that response's `structuredContent`. It disables itself while pending and
   shows a non-destructive inline error on failure.
7. Answer `ui/resource-teardown` with an empty success result and remove
   observers/listeners.

Use a monotonically increasing request id and a pending-request map. Accept
messages only when `event.source === window.parent`; do not interpret arbitrary
window messages as host traffic.

The bridge may feature-detect `window.openai` only for optional ChatGPT polish
later. The v1 feature set has a standard MCP Apps equivalent for everything it
needs, so no ChatGPT-only runtime API is required.

No automatic polling. A dashboard containing Live Activities can be expensive
and misleading if an invisible iframe continues polling. Refresh is explicit;
the model can also call the corresponding render tool again when the user asks
for current state.

### Layout and behavior

- Focused-card mode renders exactly one card and sizes the inline component to
  it. It must not add dashboard chrome or reserve space for other cards.
- Dashboard mode renders running Live Activities first, followed by cards.
- Dashboard mode uses a one-column inline layout and a responsive grid when
  fullscreen or wide enough for two columns.
- Preserve server order. Do not invent a second priority or sort rule.
- Show clear independent empty states for no activities and no cards.
- Keep actions display-only in v1: their labels may be omitted, but no control
  may imply it can run an action.
- Do not make `deepLink` clickable in v1. Host-mediated `ui/open-link` can be a
  later addition with an explicit navigation policy.
- Format dates and countdown labels using host locale/timezone when supplied,
  falling back to the browser defaults used by the guest page today.
- Map host CSS variables onto 00Widget tokens, with the existing light/dark
  palette as fallback. Never depend on one host's product name.
- Preserve the renderer's existing semantic cues: meaning is communicated by
  text/marks as well as color, chart labels are escaped, and SVGs have useful
  labels or are correctly hidden from accessibility.

## Backward-compatibility contract

During the current review, the stable channel is unchanged. The preview
channel is additive and isolated by URL:

| Surface | Compatibility rule |
| --- | --- |
| Submitted `/mcp` endpoint | Tool order, descriptors, discovery capabilities, empty resource lists, prompts, and tool behavior remain deeply equal to the pre-change endpoint. |
| `/mcp-preview` endpoint | Starts from the stable contract, then appends `render_card` and `render_dashboard` and advertises one UI resource. |
| Existing tool descriptors | Deeply equal in both channels; no UI metadata is added to them. |
| Existing tool calls | Same validation, authorization, handlers, `content`, and `structuredContent` in both channels. |
| Existing non-UI clients | Remain configured to `/mcp`; after promotion they may ignore the new tools or call them as normal read tools with text plus JSON. |
| `initialize` / `server/discover` | Stable remains unchanged during review. Preview truthfully adds `resources`; existing `tools` capability and protocol-version behavior stay intact. |
| Resource probes | Stable keeps the current empty lists. Preview lists one exact resource; templates and prompts remain empty. |
| Cached clients | Old descriptors continue to call old tools. Old resource URIs remain readable across template revisions. |
| OAuth and scopes | No new scope. Preview has its own protected-resource identity on the same authorization server. Both render tools require `read`. |
| REST API and Apple clients | No route, schema, state, or renderer contract changes. |

The endpoint is stateless across HTTP requests, so it cannot remember the UI
extension advertised by a prior `initialize` request. Do not introduce a fake
session solely to capability-filter `tools/list`. Select a static descriptor
set from the routed channel instead. Within the preview channel, publish the
render tools and their standard `_meta` unconditionally: `_meta` is the
protocol's extension point, each tool has a full headless fallback, and a host
without MCP Apps has no reason to call `resources/read`.

Do not decorate `get_card` or `get_dashboard` instead. That would make cheap,
general-purpose reads mount UI in supporting hosts on every call and would
couple future visual changes to the most common headless read paths.

## File-level implementation plan

1. `server/src/webPreview.ts`
   - Extract styles and pure browser render functions from `guestPage.ts`.
   - Add dashboard composition and host-token CSS fallbacks.
2. `server/src/guestPage.ts`
   - Reduce to page shell, guest fetch adapter, expiry/CTA, and CSP response.
   - Keep the existing external response and headers unchanged.
3. `server/src/mcpApp.ts`
   - Define the versioned resource descriptor.
   - Generate the self-contained HTML and standards-first postMessage bridge.
4. `server/src/mcp.ts`
   - Accept an explicit stable/preview channel in handlers and discovery.
   - Extend `McpTool` with optional descriptor metadata and successful-content
     formatter.
   - Add `render_card` by reusing `CardOutput` and the `get_card` adapter.
   - Add `render_dashboard` by reusing `DashboardOutput` and the
     `get_dashboard` adapter.
   - Merge UI metadata into only those two descriptors on the preview channel.
   - Advertise and dispatch resources on preview; preserve stable responses.
5. `server/src/mcpOAuth.ts`
   - Generate protected-resource metadata and 401 challenges for the exact
     stable or preview resource path while keeping one authorization server.
6. `server/src/index.ts`
   - Add the gated `/mcp-preview`, `/mcp-preview.json`, and path-specific
     protected-resource routes; pass the channel explicitly.
7. `server/src/types.ts` and `server/wrangler.toml.sample`
   - Add optional `MCP_PREVIEW_ENABLED`; default false.
8. `server/test/guestPage.test.ts`
   - Point the existing parity/security harness through the extracted runtime.
9. `server/test/webPreview.test.ts`
   - Exercise dashboard composition and both resource kinds directly.
10. `server/test/mcpApp.test.ts`
   - Exercise the resource HTML and bridge against a fake parent window.
11. `server/test/mcp.test.ts` and `server/test/mcpOAuth.test.ts`
   - Add channel isolation, resource, metadata, schema, auth, and render-tool
     cases.
12. `server/README.md` and root `README.md`
   - Document the preview connection, optional MCP Apps behavior, promotion,
     and headless fallback.

No new migration, Worker binding, database, hostname, or production secret is
required. One non-secret environment flag and three preview HTTP routes are
added. The same Worker deployment serves both channels, so stable-channel
regression tests are a release gate.

## Required tests

### Protocol tests

- With preview disabled, every preview route returns 404.
- Stable `initialize`, `server/discover`, `tools/list`, prompts, and both
  resource-list methods are deeply equal to their pre-change fixtures.
- Preview `initialize` and `server/discover` advertise tools and resources
  while preserving protocol-version behavior, including conditional
  `resultType`.
- Preview `resources/list` returns the one exact UI resource and existing
  TTL/cache fields in the revision-appropriate shape.
- `resources/read` returns the exact URI, MIME type, HTML, CSP, and component
  metadata; missing or non-string URIs are invalid params and unknown URIs are
  not found.
- Only `render_card` and `render_dashboard`, and only on preview before
  promotion, carry `_meta.ui.resourceUri` and the OpenAI alias.
- Every descriptor that existed before this change is deeply equal to its old
  form.
- Both render tools are read-only, non-destructive, idempotent, and require
  `read` scope.
- Their `structuredContent` satisfies `CardOutput` or `DashboardOutput`; their
  published output schemas remain recursively open and unbounded.
- Headless calls receive concise text and the complete focused or dashboard
  snapshot.
- Anonymous resource and tool requests follow the current OAuth challenge;
  adding UI must not create an unauthenticated path to dashboard data.
- Stable and preview 401s advertise different protected-resource metadata
  paths, and each metadata document names the exact corresponding resource.
- A token authorized through preview works only according to its scopes; the
  preview path adds no authorization bypass or extra scope.

### Renderer tests

- Preserve every existing guest-page fixture: producer suppression,
  comparison meaning, all chart styles, semantic series/categories, timeline,
  briefing, breakdown, progress fallback, activity items, and activity signal.
- Render a mixed dashboard, cards-only dashboard, activities-only dashboard,
  and completely empty dashboard.
- Render every card template by itself in focused-card mode without dashboard
  headings, empty-state copy, or a second-card slot.
- Ignore malformed optional fields rather than throwing away the entire view.
- Escape text and attribute contexts, including card ids, labels, timeline
  labels, deep links, semantic strings, and server error text.
- Never interpolate unknown status/signal/role/flow values into CSS classes.
- Do not render webhook ids, private action payloads, bearer tokens, or tool
  result `_meta`.

### Bridge tests

- Correct `ui/initialize` → `ui/notifications/initialized` order.
- No tool result is expected before initialization completes.
- Initial and refreshed `structuredContent` both render.
- Focused refresh makes exactly one `get_card` call with the rendered id;
  dashboard refresh makes exactly one `get_dashboard` call. Both handle result,
  error, and cancellation states.
- Host-context changes update theme/locale/size without losing the snapshot.
- Resize notifications are debounced.
- Messages from a window other than `parent` are ignored.
- Teardown removes observers and answers the host.

### Regression and host checks

```sh
cd server
npm run typecheck
npm test
```

Then validate the deployed/tunnelled endpoint at increasing fidelity:

1. MCP Inspector against both URLs: prove stable has not changed, then verify
   preview handshake, tools, resources, auth, schemas, and headless render
   results.
2. The MCP Apps basic host: resource load, bridge lifecycle, initial render,
   refresh, resize, theme, and fullscreen.
3. ChatGPT Developer Mode using a separately named `00Widget Preview`
   connection: OAuth, focused-card versus overview tool selection, inline
   component, refresh, empty state, and a mixed fixture containing every card
   template plus a Live Activity. Select Refresh after every metadata or UI URI
   change, then start a new conversation.
4. One non-UI client already used with 00Widget: old tools still list and call
   normally; the new tool degrades to text plus structured data.

## Acceptance criteria

- The submitted `/mcp` endpoint has no metadata or behavioral diff while the
  existing OpenAI review is active.
- `/mcp-preview` can be independently connected, refreshed, tested, disabled,
  and rolled back without changing the submitted connection URL.
- Asking to "show me the solar widget" selects `render_card` with the solar
  card id and opens a component containing only that card.
- Asking to "show my 00Widget dashboard" selects `render_dashboard` and opens
  one inline component with the current cards and activities.
- Asking an agent to publish/update/end state follows the exact existing tool
  path and does not mount a component.
- Refresh updates the mounted component without creating a second iframe.
- Disconnecting UI support does not make any current workflow worse: every old
  tool and both render tools remain complete headless MCP tools.
- Guest links look and behave the same after renderer extraction.
- The component performs no direct network request and receives no API token.
- All server tests and typecheck pass, followed by one real MCP Apps host pass.

## Rollout

1. Add stable-channel golden tests before refactoring. They must cover
   discovery, descriptor order and contents, prompts, resources, and OAuth
   resource identity.
2. Ship renderer extraction alone and verify guest-page parity.
3. Ship the preview routes, resource methods, `render_card`, and
   `render_dashboard` with `MCP_PREVIEW_ENABLED=false`. Verify `/mcp` against
   the golden fixtures in production.
4. Set `MCP_PREVIEW_ENABLED=true`, connect
   `https://api.00widget.com/mcp-preview` as `00Widget Preview` in Developer
   Mode, and run the focused-card and dashboard evaluation set. Do not use Scan
   Tools on the in-review submission.
5. Bump the preview candidate resource URI when cached HTML would obstruct an
   iteration. Refresh the Developer Mode connection and start a new chat after
   each descriptor or URI change.
6. Watch MCP error logs for preview `resources/read`, bridge initialization
   failures, and descriptor validation. The HTML itself has no backend
   telemetry in v1.
7. After the current review completes, freeze the accepted component at
   `ui://00widget/preview/v1.html`, rerun the evaluation set, and promote that
   exact descriptor/resource set to `/mcp`. Follow the applicable OpenAI update
   flow at that time; do not alter the in-review draft to point at preview.
8. Keep every promoted resource URI readable when a later UI version ships.

## Sources checked 2026-09-25

- OpenAI, [Add UI to your MCP server](https://developers.openai.com/plugins/build/chatgpt-ui)
  — standards-first bridge, decoupled render tools, MIME type, CSP, and URI
  versioning.
- OpenAI, [Plugin UI reference](https://developers.openai.com/plugins/reference)
  — tool/resource metadata, compatibility aliases, result visibility, and
  output-schema requirements.
- OpenAI, [Build an MCP server](https://developers.openai.com/plugins/build/mcp-server)
  — backward-compatible tools, resource versioning, and deployment checks.
- OpenAI, [Connect and test your plugin](https://developers.openai.com/plugins/deploy/connect-chatgpt)
  — separate Developer Mode MCP connections, HTTPS or secure tunnels, metadata
  refresh, and starting a new conversation after changes.
- OpenAI, [Remote MCP server review requirements](https://developers.openai.com/plugins/deploy/app-review)
  — submission-time metadata snapshots, review-time endpoint stability, and
  continuous review after publication.
- MCP Apps, [stable 2026-01-26 specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)
  — `ui://` resources, `resources/read`, capability negotiation, lifecycle,
  postMessage messages, sizing, and headless fallback.
