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

All endpoints except `/health` require `Authorization: Bearer <api-key>`.

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
