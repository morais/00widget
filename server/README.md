# 00Widget — Server

A Cloudflare Worker that accepts webhook-style updates from any agent and fans out to iOS via WidgetKit + ActivityKit push notifications.

## Prerequisites

- Node 22+
- A Cloudflare account (free tier is fine)
- A domain in that Cloudflare account for the production API
- The Wrangler CLI — installed as a devDependency; invoke as `npx wrangler`.

## First-time setup

```bash
cd server
npm install
cp wrangler.toml.sample wrangler.toml   # gitignored — your local config
```

`wrangler.toml.sample` is the committed source-of-truth template. `wrangler.toml` is gitignored and holds your per-developer values (D1 database id, custom domain, and anything else you customize per deployment). Re-copy + re-edit if upstream `wrangler.toml.sample` changes.

Replace the sample `api.example.com` route with your API hostname. Production disables both the generated `workers.dev` hostname and preview URLs so they cannot bypass access controls attached to the custom domain. Local `wrangler dev` remains available on localhost.

### 1. Create storage

```
npx wrangler d1 create zerozerowidget
```

Copy the D1 `database_id` into `[[d1_databases]]` in your local `wrangler.toml`.

Apply the schema locally or remotely before running against that database:

```
npx wrangler d1 migrations apply zerozerowidget --local
npx wrangler d1 migrations apply zerozerowidget --remote
```

Create the delayed delivery queue named by `wrangler.toml`:

```
npx wrangler queues create zerozerowidget-widget-reloads
```

The Worker is both producer and consumer. Wrangler attaches both bindings on
deploy; no scheduled trigger is required.

### 2. Configure local secrets

```
install -m 600 .dev.vars.example .dev.vars
```

Edit `.dev.vars` (gitignored and created with owner-only permissions) and set at least `SESSION_SECRET`. Generate each admin secret independently with `openssl rand -base64 32`; values shorter than 32 bytes, low-diversity values, and known placeholders are rejected. Set `API_KEYS` plus `ADMIN_API_TOKEN_LOGIN=true` only if you need the local admin bootstrap fallback. `API_KEYS` is only for the admin fallback login; app/agent bearer tokens are created from `/admin` and stored hashed in D1.

### 3. Run locally

```
npx wrangler dev
```

Then:

```
curl http://localhost:8787/health
```

If you enabled the fallback, open `http://localhost:8787/login`, sign in with the `API_KEYS` fallback token, create an API token for a tenant owner email, and use that generated token for `/v1/*` calls:

```
curl -H "Authorization: Bearer <generated-api-token>" http://localhost:8787/v1/cards
```

### 4. Deploy

Confirm that `wrangler.toml` contains your custom API hostname and keeps `workers_dev = false` and `preview_urls = false`, then deploy:

```
npx wrangler deploy
```

For production, store secrets with `wrangler secret put`:

```
npx wrangler secret put API_KEYS
npx wrangler secret put SESSION_SECRET
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_PRIVATE_KEY     # paste the PEM, including \n linebreaks
npx wrangler secret put APNS_BUNDLE_ID
```

`APNS_ENV` lives in `wrangler.toml` as a plain var (`sandbox` or `production`).

### API abuse controls

Generated app and publisher bearer tokens have a fixed `zw_` or `zwa_` format.
Malformed values are rejected before hashing, rate limiting, or D1 access. Validly
shaped tokens then pass through two Workers Rate Limiting bindings before D1: a
600-request/minute source-IP circuit breaker and a 300-request/minute token
fingerprint circuit breaker. These counters are intentionally generous and
fail open if Cloudflare's limiter is temporarily unavailable; they are abuse
protection, not tenant quotas.

For a production custom domain, add a zone-level WAF rate-limiting rule as an
outer circuit breaker too. The Free-plan-compatible baseline is URI path
`/v1/*`, counting by source IP, 100 requests per 10 seconds, with a 10-second
block. Higher plans can additionally count authentication failures by response
status. Keep `workers_dev` and preview URLs disabled so requests cannot bypass
the custom-domain rule.

## Web sign-in

**`/login`** authenticates a person in the browser. It is not an admin login: any
account created in the iOS app can sign in, and administration is a separate
capability layered on top (see "Admin capabilities" below).

Signing in never signs anyone up. The callback resolves the Apple identity
against `apple_accounts` — the same table the iOS app writes — falling back to a
tenant whose `owner_email` matches, and turns away an identity it does not
recognise. Accounts are created in the app; someone who merely finds this
endpoint does not become a tenant by visiting a URL. Set
`WEB_SIGNUP_ENABLED = "true"` to let web sign-in create a tenant as well. It is
off by default.

Two sign-in methods, either is sufficient:

- **Sign in with Apple** — the normal path, for everyone. Setup below.
- **API-token bootstrap** — uses one of the `API_KEYS` values, grants admin
  capabilities without an identity, and owns no tenant. It exists for a
  deployment with no accounts yet. Disabled by default; enable with
  `ADMIN_API_TOKEN_LOGIN=true`.

What a signed-in person can do today is sign in, sign out, and approve an MCP
connector for their own account. There is no user-facing dashboard yet; `/admin`
remains administrators-only.

### Admin capabilities

`ADMIN_EMAILS` no longer gates authentication — it names the addresses whose
sessions carry `isAdmin`. Every route under `/admin` asserts that capability;
being signed in is never enough. The check runs when the session is *read*, so
adding or removing an address takes effect on the next request rather than at
the next login, and a session that loses admin keeps working as an ordinary one.

A deployment with no `ADMIN_EMAILS` is valid: web sign-in works and `/admin` is
unreachable for everybody.

### API-token bootstrap

Set `ADMIN_API_TOKEN_LOGIN=true`, visit `/login`, and paste any value from `API_KEYS` into the API-token form. Every comma-separated token and `SESSION_SECRET` must be an independently generated value of at least 32 bytes; insecure configuration is rejected. Session cookies are signed with `SESSION_SECRET` (so even the bootstrap path needs that secret set). Login attempts are rate-limited per client IP.

Important: `API_KEYS` values are not accepted by `/v1/*` app/agent endpoints. Use the admin dashboard to create a scoped tenant API token, copy the raw token once, and give it only to the intended app or integration. The form offers producer, read-only, device, and webhook-manager presets.

To enable temporarily:

```
npx wrangler secret put ADMIN_API_TOKEN_LOGIN
# enter: true
```

Existing bootstrap sessions stop being honored as soon as the flag is removed or set to anything other than `true` — users are redirected back to `/login`, where the API-token form is hidden.

### Sign in with Apple

#### What you need to set up at developer.apple.com

1. **Services ID** (the `client_id` Apple uses to identify the web app).
   Identifiers → "+" → **Services IDs** → e.g. `com.example.zerozerowidget.signin` (must differ from your iOS bundle id).
   Enable **Sign in with Apple** → **Configure**:
   - Primary App ID: your iOS app's App ID (the one Apple Sign-In is enabled on).
   - Domains: your custom Worker hostname, e.g. `api.example.com`.
   - Return URLs: `https://<your-worker-host>/auth/apple/callback`.
2. **Sign-In key** (the `.p8` Apple uses to sign authorization JWTs *to* your server — note: this Worker doesn't currently use the key, only the public-key JWKS, but Apple requires it on the Services ID anyway).
   Keys → "+" → enable **Sign in with Apple**, link to the same Primary App ID, download the `.p8`.
3. **Enable Sign in with Apple** on your **App ID** if it isn't already.

#### Wrangler secrets

```
npx wrangler secret put APPLE_SIGN_IN_CLIENT_ID     # the Services ID, e.g. com.example.zerozerowidget.signin
npx wrangler secret put APPLE_SIGN_IN_REDIRECT_URI  # https://<host>/auth/apple/callback
npx wrangler secret put ADMIN_EMAILS                # addresses holding admin capabilities
npx wrangler secret put SESSION_SECRET              # independently generated random 32+ byte value
```

If the Apple values are missing, `/login` renders a "not configured" view and the public API stays unaffected. If `ADMIN_EMAILS` is missing, sign-in still works and `/admin` reports that no administrator is configured. Neither page names which setting is unset — that goes to the Worker's logs, so an unauthenticated visitor gets no map of what to probe.

#### How the flow works

`GET /login/apple` redirects to `https://appleid.apple.com/auth/authorize` with `response_mode=form_post`. Apple posts the result back to `/auth/apple/callback`. The Worker validates the `id_token` against Apple's JWKS (RS256), resolves the account, and sets a 24-hour HMAC-signed `HttpOnly; Secure; SameSite=Lax` session cookie scoped to `Path=/` — the web surface spans `/admin` and `/connect`, so it is no longer one directory. `GET /logout` clears it.

An unauthenticated request to a page that needs a session is redirected to `/login?next=<path>`, and the destination is carried through Apple's cross-site form post in a short-lived cookie. Only same-origin absolute paths under `/admin` or `/connect/` are honoured, so `?next=` cannot be turned into an open redirect.

#### Privacy email relay

If someone chose "Hide My Email" on first sign-in, Apple returns a relay address like `abc123@privaterelay.appleid.com`. That exact address is what the Worker sees, so it is what an `ADMIN_EMAILS` entry must contain. Account matching prefers Apple's stable subject id over the address, so a relay or a later address change does not detach someone from their tenant.

## Admin dashboard

An HTML dashboard at **`/admin`** creates tenant API tokens, stores each tenant owner email, and lists every card, device, push token, Live Activity, pending activity, and push-to-start token in D1 — across all tenants. It requires a web session whose email is in `ADMIN_EMAILS`, or a bootstrap session.

## iOS app login

The iOS app can optionally use native Sign in with Apple instead of asking the user to paste a tenant API token. When enabled, the app posts Apple's `identityToken` to `POST /v1/auth/apple/token`; the Worker validates the token against Apple's JWKS and creates three 90-day credentials in one revocable session: a widget-visible device credential (`read`, `device:register`, `actions:run`), an app-only credential (`actions:confirm`, `shares:manage`), and an app-only stored publisher credential (`read`, `publish`) that the user can copy for agents. Signing out calls `DELETE /v1/auth/token`, revokes all three, and removes that device's APNs, widget, and Live Activity registrations.

All newly created API tokens expire after 90 days. The migration also gives existing tokens a 90-day transition window. A standalone publisher token can revoke itself with `DELETE /v1/auth/token`; the endpoint also accepts an expired token solely so it can clean up its own registrations.

Required Worker secrets:

```
npx wrangler secret put APPLE_APP_LOGIN_ENABLED       # enter: true
npx wrangler secret put APPLE_APP_SIGN_IN_CLIENT_ID   # native app bundle id, e.g. com.example.zerozerowidget
```

The iOS app target also needs the Sign in with Apple capability. In this repo that is configured from `ios/project.yml` / `ios/project.yml.sample` via `com.apple.developer.applesignin`, and the Settings UI is enabled with the `ZWAppleLoginEnabled` Info.plist flag.

## APNs setup

1. Log in to [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers & Profiles → Keys → "+".
2. Enable **Apple Push Notifications service (APNs)**.
3. Download the `.p8` — this is your private key. You cannot download it twice.
4. Record the **Key ID** (10 characters) and your **Team ID**.
5. Store those four values as Wrangler secrets above.

The Worker never stores the `.p8` to disk; it's kept only as a secret.

## Endpoints

The routes a producer, an agent, or the iOS app calls. Deliberately not the
whole router — these are excluded, and adding them here would suggest they are
something to integrate against:

- `/v1/shares/*` and `/v1/guest/*`. Sharing between accounts and read-only guest
  links are driven from the iOS app, on credentials it holds itself. A guest
  token reaches exactly two routes and no others, which is the enforcement; see
  the note on guest links in `AGENTS.md`.
- `/v1/subscription`, `/v1/subscription/verify`, and
  `/v1/apple/subscription-notifications`. The first two are the app's StoreKit
  handshake; the third is Apple's, authenticated by the JWS signature on its
  body rather than by a credential. No integration calls any of them.
- `/v1/actions/:id/run-confirmed`. The app-only counterpart of `run`, requiring
  an app credential *and* the `actions:confirm` scope. It exists so a
  destructive or confirmed action can never be triggered from a widget.
- `/llms.md`, `/llms.txt`, `/app/g`, and
  `/.well-known/apple-app-site-association`. Documentation, the browser
  fallback page for a guest link, and Apple's associated-domains file. All are
  fetched by tools and by iOS, never by an integration.

| Method | Path                                         | Purpose                                |
| ------ | -------------------------------------------- | -------------------------------------- |
| GET    | `/health`                                    | Health check, no auth.                 |
| POST   | `/v1/cards/upsert`                           | Create or update a dashboard card.     |
| POST   | `/v1/cards/upsert-batch`                     | Store up to 32 related cards with one coalesced reload decision. |
| GET    | `/v1/cards`                                  | List all cards for the API key.        |
| GET    | `/v1/cards/:id`                              | Get one card.                          |
| DELETE | `/v1/cards/:id`                              | Delete one card.                       |
| GET    | `/v1/dashboard`                              | Fetch cards and ongoing activities in one polling-efficient response. |
| GET    | `/v1/status`                                 | What this credential may do, whether any device can receive a publish, and the remaining rate budget. |
| POST   | `/v1/devices/register`                       | Store the app APNs device token.       |
| POST   | `/v1/widgets/register-push-token`            | Reconcile WidgetKit push subscriptions. |
| POST   | `/v1/live-activities/register`               | Store an ActivityKit push token.       |
| POST   | `/v1/live-activities/register-start-token`   | Store this device's push-to-start token. |
| POST   | `/v1/live-activities/recover`                | Replay ongoing activities missing from one device. |
| POST   | `/v1/live-activities/start`                  | Start a Live Activity through APNs.    |
| GET    | `/v1/live-activities`                        | List current activities, deduplicated across pending and registered devices. `?include=ended` adds a 24-hour window of finished ones. |
| GET    | `/v1/live-activities/pending`                | Compatibility fallback for older apps. |
| POST   | `/v1/live-activities/update`                 | Push an update via APNs.               |
| POST   | `/v1/live-activities/end`                    | End a Live Activity via APNs.          |
| GET    | `/v1/integrations/webhook`                   | Read the configured action webhook URL. |
| PUT    | `/v1/integrations/webhook`                   | Create/update the action webhook; return a secret only on create/rotation. |
| DELETE | `/v1/integrations/webhook`                   | Disable action webhook delivery.       |
| POST   | `/v1/actions/:id/run`                        | Deliver an action to the configured webhook. |
| POST   | `/v1/auth/apple/token`                       | Exchange native Apple identity token for a tenant API token. |
| DELETE | `/v1/auth/token`                             | Revoke the current credential/session and device registrations. |
| GET    | `/login`                                     | Web sign-in page (Apple + bootstrap forms). |
| GET    | `/login/apple`                               | Redirects to Sign in with Apple.       |
| POST   | `/login/api-token`                           | API-token bootstrap login.             |
| GET    | `/logout`                                    | Clears the session cookie.             |
| POST   | `/admin/api-keys`                            | Create a tenant API token.             |
| POST   | `/admin/api-keys/:id/revoke`                 | Revoke a tenant API token.             |
| POST   | `/auth/apple/callback`                       | Apple form-post callback.              |
| GET    | `/admin`                                     | Privileged administrative dashboard (HTML). Requires the admin capability. |
| POST   | `/mcp`                                       | MCP endpoint (Streamable HTTP, JSON-RPC). Off unless `MCP_ENABLED=true`. |
| GET    | `/mcp.json`                                  | Generated MCP client config for this deployment. |
| GET    | `/.well-known/oauth-protected-resource`      | RFC 9728 metadata for `/mcp`.          |
| GET    | `/.well-known/oauth-authorization-server`    | RFC 8414 metadata.                     |
| POST   | `/oauth/register`                            | Dynamic client registration (RFC 7591). |
| GET    | `/connect/mcp/authorize`                     | Consent screen; needs any web session. |
| POST   | `/connect/mcp/authorize`                     | Approve or deny, returning an authorization code. |
| POST   | `/oauth/token`                               | PKCE code exchange; returns a tenant API token. |

All `/v1/*` endpoints require `Authorization: Bearer <api-key>`. Each authenticated route also requires one explicit capability; a valid token without it receives `403`. `/admin/*` is gated by the admin session cookie set after Sign in with Apple — see "Admin dashboard" below.

| Scope | Capabilities |
| ----- | ------------ |
| `read` | Read cards, dashboard state, and Live Activities. Answers to its former name `tenant:read` on credentials issued before the rename. |
| `publish` | Upsert/delete cards and start/update/end Live Activities. |
| `device:register` | Register device, WidgetKit, and ActivityKit push tokens. |
| `actions:run` | Run safe, non-confirmed card actions. |
| `actions:confirm` | Run confirmed/destructive actions; additionally requires an app credential. |
| `shares:manage` | Create, list, accept, decline, and revoke shares. |
| `webhook:manage` | Read, create, update, rotate, or delete the action webhook. Not granted to MCP-minted tokens. |

A bare verb spans resources; a prefix names the one thing the scope touches. `read` and `publish` both cover cards and Live Activities, so neither carries a prefix; everything narrower or administrative does. Keep a new scope on that rule.

Route declarations in `src/index.ts` must name a scope; there is no implicit
publisher access. Existing publisher tokens receive an explicit compatibility
scope set during migration and retain it only until their normal expiry. Newly
created credentials always use a least-privilege preset.

The iOS app treats WidgetKit's callback as a canonical subscription snapshot:

```json
{
  "deviceId": "stable-installation-id",
  "widgetPushToken": "abcdef012345...",
  "subscriptions": [
    {
      "widgetKind": "ZeroZeroWidgetCardWidget",
      "cardIds": ["solar-home"],
      "allCards": false
    }
  ]
}
```

Sending `subscriptions: []` without a token removes that device's WidgetKit subscriptions. If WidgetKit reuses a token after an app reinstall, canonical registration moves it to the new device snapshot and removes the orphaned rows. The original single-`widgetKind` request remains accepted for compatibility with older installed builds.

## MCP (Model Context Protocol)

`POST /mcp` exposes the publishing surface as MCP tools, so a host that speaks
MCP — a ChatGPT connector, Claude, an editor — can publish without anyone
writing an integration. Set `MCP_ENABLED = "true"` in `wrangler.toml` to turn it
on; every route in the table above returns 404 otherwise, as it does when
`SESSION_SECRET` is missing or weak.

The tools call the same handlers as the `/v1/*` routes and take the same zod
schemas as arguments, converted to JSON Schema at startup — there is no second
implementation to keep in sync. The transport is stateless: one POST, one JSON
response, no SSE and no session id.

Authorization is OAuth 2.1 because ChatGPT connectors cannot present a custom
API key or header — the only credentials they carry are OAuth tokens. The flow
is: the client registers itself (`/oauth/register`), sends the person to
`/connect/mcp/authorize`, and exchanges the resulting code with PKCE at
`/oauth/token`. What comes back is an ordinary tenant API token with the
producer scopes, listed and revocable in `/admin` like any other. A caller that
*already* holds a `zw_` token can skip all of this and send it to `/mcp`
directly.

### What ChatGPT actually calls

Its client is `openai-mcp/1.0.0`, speaking the **2026-07-28** revision. In order:
an empty `POST /mcp` probe (answered 202), `server/discover`, `tools/list`, then
`tools/call`. All three JSON-RPC calls carry a credential, so all three require
one. The probe carries no message at all, which is why it is answered rather
than challenged.

`server/discover` must return `supportedVersions` as a list, `capabilities`, and
`serverInfo` under `_meta["io.modelcontextprotocol/serverInfo"]`. The legacy
`initialize` shape — a single `protocolVersion` string and a top-level
`serverInfo` — is silently rejected: the client stops after discovery and the
connector reports itself installed while exposing no callable function.

Two `console.warn` lines on the endpoint (`mcp request rejected`,
`mcp body rejected`) carry the user agent and the reason. They exist because a
failing connector is otherwise undiagnosable from outside: the client retries
discovery and surfaces its own generic error, and nothing about which request
failed, or whether it carried a credential, is visible in status codes alone.

Registered clients and authorization codes are signed values rather than rows —
no table, no migration, no sweep. A code lives 60 seconds and is bound to its
PKCE challenge; see the header comment in `src/mcpOAuth.ts` for what that does
and does not buy.

Approving needs a web session, not admin: connecting a client to your own
account is something any signed-in person may do. The tenant is never read from
the form — it is re-resolved from the signed-in identity while the code is
issued — so a connector can only ever be pointed at the approver's own account.
That holds for administrators too; issuing a credential for someone else is what
`/admin` is for, and should be deliberate.

## Storage layout

Primary storage is D1. App/agent tokens live in `api_keys`, each token maps to a `tenant_id` and an explicit `scopes_json` capability list, and only `sha256(rawToken)` is stored. Tenants store an `owner_email` for ops/account ownership. Application data tables are scoped by `tenant_id`, while `api_key_hash` remains on rows for audit/debugging.

Tables:

| Table | Primary key | Purpose |
| ----- | ----------- | ------- |
| `tenants` | `id` | Customer/workspace tenants, including `owner_email`. |
| `api_keys` | `id` | Hashed bearer tokens mapped to tenants. |
| `cards` | `(tenant_id, id)` | Public dashboard-card rendering state. |
| `action_payloads` | `(tenant_id, card_id, action_id)` | Write-only action context, omitted from card APIs and device caches. |
| `devices` | `(tenant_id, device_id)` | Registered iOS app devices. |
| `widget_tokens` | `(tenant_id, device_id, widget_kind)` | WidgetKit push tokens, card-level subscriptions, app build, and platform. |
| `widget_push_cadence` | `token` | Last push and remaining allowance per widget, as a token bucket refilled by elapsed time. |
| `widget_push_pending` | `tenant_id` | One generation-counted row coalescing cadence-suppressed or transiently failed reloads until its delayed queue message can deliver them. |
| `activity_instances` | `id` | Canonical owner-scoped Live Activities; `(owner_tenant_id, external_id)` is unique. |
| `activity_targets` | `(activity_instance_id, target_tenant_id)` | Exact owner or accepted-share audiences authorized to receive an instance. |
| `activity_deliveries` | `(activity_instance_id, target_tenant_id, device_id)` | Per-device ActivityKit push tokens bound to an exact instance and optional share. |
| `start_tokens` | `(tenant_id, device_id, attributes_type)` | ActivityKit push-to-start tokens. |
| `activity_history` | `(tenant_id, activity_instance_id)` | Live Activities that ended in the last 24 hours, so a producer can reconcile. Swept with the rate limit buckets. |
| `webhook_integrations` | `tenant_id` | Per-tenant action webhook URL and signing secret. |

The Worker uses D1 only.

## Tests

```
npm test
```

Covers auth, card CRUD, webhook action delivery, WidgetKit subscription targeting and APNs retry/pruning, Live Activity registration, and APNs payload construction (no network calls except mocked fetches).

## APNs payload notes

The Worker constructs payloads that match the documented ActivityKit / WidgetKit formats:

- **Live Activity start** — `event: "start"`, complete Codable `content-state`, `attributes-type`, `attributes`, required `alert`, and `input-push-token: 1` so iOS returns the per-activity token used for subsequent pushes.
- **Live Activity recovery** — the iOS app compares the authoritative server list with local ActivityKit instances on launch, foreground, and Activities-screen refresh. Missing instances are replayed with their original `activityInstanceId` and complete state to only that device's push-to-start token. The endpoint requires `device:register`, verifies device-bound credentials and target-tenant access, and is rate-limited per tenant/device/activity.
- **Live Activity update** — `apns-push-type: liveactivity`, `apns-topic: <bundleId>.push-type.liveactivity`, body `{ aps: { timestamp, event: "update", "content-state": {...}, "stale-date": ..., "relevance-score": ... } }`. `relevance-score` is optional and ranks the activity in the iPhone and Apple Watch Smart Stack. When `endsAt` is present, `countdownGranularity` is preserved in content state as `second` (default) or `minute`; minute mode is rendered locally without additional pushes. Composite `items` are carried in content state as a complete snapshot and are retained when an update omits the field. The Worker rejects static attributes plus content state above ActivityKit's combined 4 KiB limit.
- **Live Activity end** — same headers, `event: "end"`, complete final `content-state`, and a `dismissal-date` in the past for immediate removal by default. Producers can provide an explicit future `dismissalDate` within Apple's four-hour window to keep the final state visible briefly.
- **WidgetKit push** — `apns-push-type: widgets`, `apns-topic: <bundleId>.push-type.widgets`, `content-changed: true`, a short expiration, and a stable collapse id because every reload fetches the latest card state. Batch upserts make one reload decision for all cards, and reloads are bounded per widget by a token bucket — at least 5 minutes apart, six available back-to-back, one refilling every 40 minutes — because Apple budgets reloads per widget instance and counts pushes against the same allowance as the widget's own refreshes. A bucket rather than a daily quota so a busy morning cannot leave the widget dark all afternoon. Changes arriving inside that window update one durable `widget_push_pending` row; one delayed Cloudflare Queue message delivers the latest coalesced state when the window opens. Permanent token failures are pruned; transient APNs failures use bounded in-request retries and retain and retry the coalesced row. An empty queue does not invoke the Worker, and diagnostics use failure logs plus sampled successes rather than per-push history.

These shapes are documented in `src/apns.ts` with the verification date. Re-check Apple's live documentation before changing them; push payload details (priority, required fields, `attributes`/`attributes-type` for push-to-start, `content-state` encoding) have shifted between iOS versions.
