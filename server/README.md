# 00Widget — Server

A Cloudflare Worker that accepts webhook-style updates from any agent and fans out to iOS via WidgetKit + ActivityKit push notifications.

## Prerequisites

- Node 20+
- A Cloudflare account (free tier is fine)
- The Wrangler CLI — installed as a devDependency; invoke as `npx wrangler`.

## First-time setup

```bash
cd server
npm install
cp wrangler.toml.sample wrangler.toml   # gitignored — your local config
```

`wrangler.toml.sample` is the committed source-of-truth template. `wrangler.toml` is gitignored and holds your per-developer values (KV namespace id, anything else you customize per-deployment). Re-copy + re-edit if upstream `wrangler.toml.sample` changes.

### 1. Create a KV namespace

```
npx wrangler kv:namespace create ZW_KV
```

Copy the `id` it prints into your local `wrangler.toml` under `[[kv_namespaces]]`.

### 2. Configure local secrets

```
cp .dev.vars.example .dev.vars
```

Edit `.dev.vars` (gitignored) and set at least `API_KEYS`.

### 3. Run locally

```
npx wrangler dev
```

Then:

```
curl http://localhost:8787/health
curl -H "Authorization: Bearer dev-key-1" http://localhost:8787/v1/cards
```

### 4. Deploy

```
npx wrangler deploy
```

For production, store secrets with `wrangler secret put`:

```
npx wrangler secret put API_KEYS
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_PRIVATE_KEY     # paste the PEM, including \n linebreaks
npx wrangler secret put APNS_BUNDLE_ID
```

`APNS_ENV` lives in `wrangler.toml` as a plain var (`sandbox` or `production`).

## Admin dashboard (Sign in with Apple)

A read-only HTML dashboard at **`/admin`** lists every card, device, push token, Live Activity, pending activity, and push-to-start token in KV — across all API keys. Access is gated by Sign in with Apple, restricted to a configured list of admin emails.

### What you need to set up at developer.apple.com

1. **Services ID** (the `client_id` Apple uses to identify the web app).
   Identifiers → "+" → **Services IDs** → e.g. `com.example.zerozerowidget.signin` (must differ from your iOS bundle id).
   Enable **Sign in with Apple** → **Configure**:
   - Primary App ID: your iOS app's App ID (the one Apple Sign-In is enabled on).
   - Domains: your Worker hostname, e.g. `zerozerowidget-server.morais-pedro.workers.dev`.
   - Return URLs: `https://<your-worker-host>/admin/auth/apple/callback`.
2. **Sign-In key** (the `.p8` Apple uses to sign authorization JWTs *to* your server — note: this Worker doesn't currently use the key, only the public-key JWKS, but Apple requires it on the Services ID anyway).
   Keys → "+" → enable **Sign in with Apple**, link to the same Primary App ID, download the `.p8`.
3. **Enable Sign in with Apple** on your **App ID** if it isn't already.

### Wrangler secrets

```
npx wrangler secret put APPLE_SIGN_IN_CLIENT_ID     # the Services ID, e.g. com.example.zerozerowidget.signin
npx wrangler secret put APPLE_SIGN_IN_REDIRECT_URI  # https://<host>/admin/auth/apple/callback
npx wrangler secret put ADMIN_EMAILS                # comma-separated list, e.g. you@example.com
npx wrangler secret put SESSION_SECRET              # any random 32+ char string (used to sign the session cookie)
```

If any of those are missing the `/admin` page renders a "not configured" view listing what's missing — it does not crash and the public API stays unaffected.

### How the flow works

`GET /admin/login` redirects to `https://appleid.apple.com/auth/authorize` with `response_mode=form_post`. Apple posts the result back to `/admin/auth/apple/callback`. The Worker validates the `id_token` against Apple's JWKS (RS256), confirms the email is in `ADMIN_EMAILS`, and sets a 24-hour HMAC-signed `HttpOnly; Secure` session cookie. `GET /admin` reads the cookie and renders the dashboard. `GET /admin/logout` clears it.

### Privacy email relay

If the admin chose "Hide My Email" on first sign-in, Apple returns a relay address like `abc123@privaterelay.appleid.com`. Add that exact address to `ADMIN_EMAILS` rather than the underlying Apple ID — the Worker only sees the relay.

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
| GET    | `/v1/cards`                                  | List all cards for the API key.        |
| GET    | `/v1/cards/:id`                              | Get one card.                          |
| DELETE | `/v1/cards/:id`                              | Delete one card.                       |
| POST   | `/v1/devices/register`                       | Store the app APNs device token.       |
| POST   | `/v1/widgets/register-push-token`            | Store a WidgetKit push token.          |
| POST   | `/v1/live-activities/register`               | Store an ActivityKit push token.       |
| POST   | `/v1/live-activities/start`                  | Queue a pending Live Activity.         |
| GET    | `/v1/live-activities/pending`                | List pending activities for the app.   |
| POST   | `/v1/live-activities/update`                 | Push an update via APNs.               |
| POST   | `/v1/live-activities/end`                    | End a Live Activity via APNs.          |
| POST   | `/v1/actions/:id/run`                        | Run an action (v1: logs and returns).  |
| GET    | `/admin/login`                               | Redirects to Sign in with Apple.       |
| POST   | `/admin/auth/apple/callback`                 | Apple form-post callback.              |
| GET    | `/admin/logout`                              | Clears the admin session cookie.       |
| GET    | `/admin`                                     | Read-only ops dashboard (HTML).        |

All `/v1/*` endpoints require `Authorization: Bearer <api-key>`. `/admin/*` is gated by the admin session cookie set after Sign in with Apple — see "Admin dashboard" below.

## Storage layout

All KV keys are prefixed with `<apiKeyHash>` where `apiKeyHash = hex(sha256(apiKey))`, so keys are isolated per credential.

```
card:<h>:<cardId>
cards-index:<h>
device:<h>:<deviceId>
widget-token:<h>:<deviceId>:<widgetKind>
activity:<h>:<externalActivityId>
pending-activity:<h>:<externalActivityId>
```

## Tests

```
npm test
```

Covers auth, card CRUD, Live Activity registration, and APNs payload construction (no network calls).

## APNs payload notes

The Worker constructs payloads that match the documented ActivityKit / WidgetKit formats:

- **Live Activity update** — `apns-push-type: liveactivity`, `apns-topic: <bundleId>.push-type.liveactivity`, body `{ aps: { timestamp, event: "update", "content-state": {...}, "stale-date": ... } }`.
- **Live Activity end** — same headers, `event: "end"`, optional `dismissal-date`.
- **WidgetKit push** — `apns-push-type: widgets`, `apns-topic: <bundleId>.push-type.widgets`.

These shapes are marked `TODO(apns):` in `src/apns.ts` as a reminder to cross-check against the latest Apple documentation before deploying to production — push payload details (priority, required fields, `attributes`/`attributes-type` for push-to-start, `content-state` encoding) have shifted between iOS versions.
