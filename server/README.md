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

Edit `.dev.vars` (gitignored and created with owner-only permissions) and set at least `SESSION_SECRET`. Set `API_KEYS` plus `ADMIN_API_TOKEN_LOGIN=true` only if you need the local admin bootstrap fallback. `API_KEYS` is only for the admin fallback login; app/agent bearer tokens are created from `/admin` and stored hashed in D1.

### 3. Run locally

```
npx wrangler dev
```

Then:

```
curl http://localhost:8787/health
```

If you enabled the fallback, open `http://localhost:8787/admin/login`, sign in with the `API_KEYS` fallback token, create an API token for a tenant owner email, and use that generated token for `/v1/*` calls:

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

## Admin dashboard

An HTML dashboard at **`/admin`** creates tenant API tokens, stores each tenant owner email, and lists every card, device, push token, Live Activity, pending activity, and push-to-start token in D1 — across all tenants.

Two sign-in methods, either is sufficient:

- **Sign in with Apple** — production; restricted by `ADMIN_EMAILS`. Setup below.
- **API-token fallback** — uses one of the `API_KEYS` bootstrap values. Disabled by default; enable with `ADMIN_API_TOKEN_LOGIN=true` only while you sort out Sign in with Apple or local bootstrap.

### API-token fallback

Set `ADMIN_API_TOKEN_LOGIN=true`, visit `/admin/login`, and paste any value from `API_KEYS` into the API-token form. Session cookies are signed with `SESSION_SECRET` (so even the fallback path needs that secret set). Login attempts are rate-limited per client IP.

Important: `API_KEYS` values are not accepted by `/v1/*` app/agent endpoints. Use the admin dashboard to create a tenant API token, copy the raw token once, and give that generated token to the iOS app or publishing agent.

To enable temporarily:

```
npx wrangler secret put ADMIN_API_TOKEN_LOGIN
# enter: true
```

Existing API-token sessions stop being honored as soon as the flag is removed or set to anything other than `true` — users are redirected back to `/admin/login`, where the API-token form is hidden.

### Sign in with Apple

#### What you need to set up at developer.apple.com

1. **Services ID** (the `client_id` Apple uses to identify the web app).
   Identifiers → "+" → **Services IDs** → e.g. `com.example.zerozerowidget.signin` (must differ from your iOS bundle id).
   Enable **Sign in with Apple** → **Configure**:
   - Primary App ID: your iOS app's App ID (the one Apple Sign-In is enabled on).
   - Domains: your custom Worker hostname, e.g. `api.example.com`.
   - Return URLs: `https://<your-worker-host>/admin/auth/apple/callback`.
2. **Sign-In key** (the `.p8` Apple uses to sign authorization JWTs *to* your server — note: this Worker doesn't currently use the key, only the public-key JWKS, but Apple requires it on the Services ID anyway).
   Keys → "+" → enable **Sign in with Apple**, link to the same Primary App ID, download the `.p8`.
3. **Enable Sign in with Apple** on your **App ID** if it isn't already.

#### Wrangler secrets

```
npx wrangler secret put APPLE_SIGN_IN_CLIENT_ID     # the Services ID, e.g. com.example.zerozerowidget.signin
npx wrangler secret put APPLE_SIGN_IN_REDIRECT_URI  # https://<host>/admin/auth/apple/callback
npx wrangler secret put ADMIN_EMAILS                # comma-separated list, e.g. you@example.com
npx wrangler secret put SESSION_SECRET              # any random 32+ char string (used to sign the session cookie)
```

If any of those are missing the `/admin` page renders a "not configured" view listing what's missing — it does not crash and the public API stays unaffected.

#### How the flow works

`GET /admin/login` redirects to `https://appleid.apple.com/auth/authorize` with `response_mode=form_post`. Apple posts the result back to `/admin/auth/apple/callback`. The Worker validates the `id_token` against Apple's JWKS (RS256), confirms the email is in `ADMIN_EMAILS`, and sets a 24-hour HMAC-signed `HttpOnly; Secure` session cookie. `GET /admin` reads the cookie and renders the dashboard. `GET /admin/logout` clears it.

#### Privacy email relay

If the admin chose "Hide My Email" on first sign-in, Apple returns a relay address like `abc123@privaterelay.appleid.com`. Add that exact address to `ADMIN_EMAILS` rather than the underlying Apple ID — the Worker only sees the relay.

## iOS app login

The iOS app can optionally use native Sign in with Apple instead of asking the user to paste a tenant API token. When enabled, the app posts Apple's `identityToken` to `POST /v1/auth/apple/token`; the Worker validates the token against Apple's JWKS and creates a paired 90-day credential session. The publisher token is shared with widgets and shown once for agents. A separately scoped app credential is stored only in the app's device-only Keychain and can run confirmed actions. Signing out calls `DELETE /v1/auth/token`, revokes the pair, and removes that device's APNs, widget, and Live Activity registrations.

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

| Method | Path                                         | Purpose                                |
| ------ | -------------------------------------------- | -------------------------------------- |
| GET    | `/health`                                    | Health check, no auth.                 |
| POST   | `/v1/cards/upsert`                           | Create or update a dashboard card.     |
| POST   | `/v1/cards/upsert-batch`                     | Store up to 32 related cards with one coalesced reload decision. |
| GET    | `/v1/cards`                                  | List all cards for the API key.        |
| GET    | `/v1/cards/:id`                              | Get one card.                          |
| DELETE | `/v1/cards/:id`                              | Delete one card.                       |
| GET    | `/v1/dashboard`                              | Fetch cards and ongoing activities in one polling-efficient response. |
| POST   | `/v1/devices/register`                       | Store the app APNs device token.       |
| POST   | `/v1/widgets/register-push-token`            | Reconcile WidgetKit push subscriptions. |
| POST   | `/v1/live-activities/register`               | Store an ActivityKit push token.       |
| POST   | `/v1/live-activities/start`                  | Start a Live Activity through APNs.    |
| GET    | `/v1/live-activities`                        | List current activities, deduplicated across pending and registered devices. |
| GET    | `/v1/live-activities/pending`                | Compatibility fallback for older apps. |
| POST   | `/v1/live-activities/update`                 | Push an update via APNs.               |
| POST   | `/v1/live-activities/end`                    | End a Live Activity via APNs.          |
| GET    | `/v1/integrations/webhook`                   | Read the configured action webhook URL. |
| PUT    | `/v1/integrations/webhook`                   | Create/update the action webhook and return its signing secret. |
| DELETE | `/v1/integrations/webhook`                   | Disable action webhook delivery.       |
| POST   | `/v1/actions/:id/run`                        | Deliver an action to the configured webhook. |
| POST   | `/v1/auth/apple/token`                       | Exchange native Apple identity token for a tenant API token. |
| DELETE | `/v1/auth/token`                             | Revoke the current credential/session and device registrations. |
| GET    | `/admin/login`                               | Login page (Apple + API-token forms).  |
| GET    | `/admin/login/apple`                         | Redirects to Sign in with Apple.       |
| POST   | `/admin/login/api-token`                     | API-token fallback login.              |
| POST   | `/admin/api-keys`                            | Create a tenant API token.             |
| POST   | `/admin/api-keys/:id/revoke`                 | Revoke a tenant API token.             |
| POST   | `/admin/auth/apple/callback`                 | Apple form-post callback.              |
| GET    | `/admin/logout`                              | Clears the admin session cookie.       |
| GET    | `/admin`                                     | Read-only ops dashboard (HTML).        |

All `/v1/*` endpoints require `Authorization: Bearer <api-key>`. `/admin/*` is gated by the admin session cookie set after Sign in with Apple — see "Admin dashboard" below.

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

## Storage layout

Primary storage is D1. App/agent tokens live in `api_keys`, each token maps to a `tenant_id`, and only `sha256(rawToken)` is stored. Tenants store an `owner_email` for ops/account ownership. Application data tables are scoped by `tenant_id`, while `api_key_hash` remains on rows for audit/debugging.

Tables:

| Table | Primary key | Purpose |
| ----- | ----------- | ------- |
| `tenants` | `id` | Customer/workspace tenants, including `owner_email`. |
| `api_keys` | `id` | Hashed bearer tokens mapped to tenants. |
| `cards` | `(tenant_id, id)` | Public dashboard-card rendering state. |
| `action_payloads` | `(tenant_id, card_id, action_id)` | Write-only action context, omitted from card APIs and device caches. |
| `devices` | `(tenant_id, device_id)` | Registered iOS app devices. |
| `widget_tokens` | `(tenant_id, device_id, widget_kind)` | WidgetKit push tokens, card-level subscriptions, app build, and platform. |
| `widget_push_cadence` | `tenant_id` | Last accepted reload window per receiving tenant, used to protect WidgetKit's daily budget. |
| `widget_push_pending` | `tenant_id` | One generation-counted row coalescing cadence-suppressed or transiently failed reloads until its delayed queue message can deliver them. |
| `activity_instances` | `id` | Canonical owner-scoped Live Activities; `(owner_tenant_id, external_id)` is unique. |
| `activity_targets` | `(activity_instance_id, target_tenant_id)` | Exact owner or accepted-share audiences authorized to receive an instance. |
| `activity_deliveries` | `(activity_instance_id, target_tenant_id, device_id)` | Per-device ActivityKit push tokens bound to an exact instance and optional share. |
| `start_tokens` | `(tenant_id, device_id, attributes_type)` | ActivityKit push-to-start tokens. |
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
- **Live Activity update** — `apns-push-type: liveactivity`, `apns-topic: <bundleId>.push-type.liveactivity`, body `{ aps: { timestamp, event: "update", "content-state": {...}, "stale-date": ..., "relevance-score": ... } }`. `relevance-score` is optional and ranks the activity in the iPhone and Apple Watch Smart Stack. When `endsAt` is present, `countdownGranularity` is preserved in content state as `second` (default) or `minute`; minute mode is rendered locally without additional pushes.
- **Live Activity end** — same headers, `event: "end"`, complete final `content-state`, and a `dismissal-date` in the past for immediate removal by default. Producers can provide an explicit future `dismissalDate` within Apple's four-hour window to keep the final state visible briefly.
- **WidgetKit push** — `apns-push-type: widgets`, `apns-topic: <bundleId>.push-type.widgets`, `content-changed: true`, a short expiration, and a stable collapse id because every reload fetches the latest card state. Batch upserts make one reload decision for all cards, and reloads are bounded to one push window per receiving tenant every 30 minutes so Apple’s daily WidgetKit budget is not exhausted. Changes arriving inside that window update one durable `widget_push_pending` row; one delayed Cloudflare Queue message delivers the latest coalesced state when the window opens. Permanent token failures are pruned; transient APNs failures use bounded in-request retries and retain and retry the coalesced row. An empty queue does not invoke the Worker, and diagnostics use failure logs plus sampled successes rather than per-push history.

These shapes are documented in `src/apns.ts` with the verification date. Re-check Apple's live documentation before changing them; push payload details (priority, required fields, `attributes`/`attributes-type` for push-to-start, `content-state` encoding) have shifted between iOS versions.
