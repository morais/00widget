<p align="center">
  <img src="./docs/brand/wordmark-horizontal.png" alt="00Widget — Widgets for all your agents." width="720">
</p>

# 00Widget

**Widgets for all your agents.**

A reusable iOS companion app and Cloudflare Worker backend that lets your web apps, automations, and agents publish structured state to iOS Home/Lock Screen widgets, Live Activities, and the Dynamic Island.

The server never sends UI — only structured state conforming to a small set of templates. The iOS app renders that state through predefined SwiftUI views.

## Pointing an agent at 00Widget from another project

If you're inside another repo (say, a CI pipeline or a home-automation script) and want to make Claude Code / Codex publish state to your 00Widget instance, paste this into the agent — it's self-contained:

```
Integrate this project with 00Widget so its state shows up on iOS widgets and Live Activities.

Read the integration contract: https://github.com/morais/00widget/blob/main/docs/llms.md
That single document is everything you need — don't pull in the rest of the 00Widget repo.

Operator-supplied env vars:
  00WIDGET_BASE_URL=https://<their-worker>.workers.dev
  00WIDGET_API_KEY=<bearer token>

Verify both work with `curl $00WIDGET_BASE_URL/health` and an authenticated `GET /v1/cards` before writing any code.

Then:
1. Identify the surfaces in this project that an iOS widget should reflect (status, build state, queue depth, in-progress jobs, etc.).
2. For each, pick a template (`summary`, `progress`, `list`, or `action`) per llms.md's decision matrix.
3. Add the smallest possible publish path — a single function that POSTs to /v1/cards/upsert with a stable `id`. No SDK, no class hierarchy.
4. If something is time-bounded with a clear end (a build, a charge cycle, a delivery), use a Live Activity instead of a card.

Constraints:
- Use a stable `id` per logical thing — never embed timestamps or run ids.
- Never put secrets or PII in card fields. They render on the Lock Screen.
- Always end Live Activities. Never make destructive actions auto-run from widgets.
- Don't publish more than ~once a minute per card unless the value actually changed.

If this project is itself a Cloudflare Worker, see the "Notes for Cloudflare Workers callers" section in llms.md — same-account integrations should use a Service Binding instead of a public HTTPS fetch.
```

## Anatomy

```
00widget/
  ios/          # SwiftUI app + WidgetKit extension + Live Activity (iOS 26+)
  server/       # Cloudflare Worker (TypeScript) — REST API + APNs fan-out
  examples/     # curl scripts showing how any agent can publish state
```

## Quick start

### 1. Backend

```
cd server
npm install
cp .dev.vars.example .dev.vars   # fill in API_KEYS + SESSION_SECRET; leave APNS_* blank for local
npx wrangler dev
```

Then:

```
curl -s http://localhost:8787/health
```

### 2. Examples

```
cd examples
cp env.example.sh env.sh         # edit BASE_URL and API_KEY
./upsert-solar.sh
```

### 3. iOS

Requires macOS with Xcode 26+, iOS 26 simulator or device, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
brew install xcodegen
cd ios
xcodegen
open ZeroZeroWidget.xcodeproj
```

In Xcode, change the bundle id and App Group to values your Apple Developer team owns (see `ios/README.md`), then run.

## Data model

See `ios/Sources/Shared/Models/` (Swift) and `server/src/types.ts` (zod) — the two are kept in lockstep.

- **DashboardCard** — a single widget tile. Templates: `summary`, `progress`, `list`, `action`.
- **LiveActivitySession** — a Lock Screen / Dynamic Island activity.
- **ActionDefinition** — a button that runs a backend-defined action via `POST /v1/actions/:id/run`.

## Admin dashboard

A read-only HTML console at `/admin` lists every card, device, push token, Live Activity, pending activity, and push-to-start token across all API keys. Two sign-in methods (either is sufficient):

- **Sign in with Apple** — restricted to emails in `ADMIN_EMAILS`.
- **API-token fallback** — paste any bootstrap value from `API_KEYS` into the form. Enabled by default; flip `ADMIN_API_TOKEN_LOGIN=false` once Apple is wired up.

Create tenant API tokens from `/admin` using the tenant owner email; those generated tokens are what the iOS app and agents use for `/v1/*`.

Setup walkthrough: `server/README.md` → "Admin dashboard".

## Documentation

- `ios/README.md` — Xcode setup, entitlements, signing.
- `server/README.md` — Worker deploy, D1 binding, APNs secrets, admin dashboard.
- `examples/README.md` — publishing state from any shell or agent.
- `docs/llms.md` — for agents (Claude Code / Codex) integrating *another* project with 00Widget.
- `docs/brand/README.md` — logo, colors, tagline rules.

## Status

Working end-to-end. Cards publish, Live Activities start/update/end, push-to-start is wired, and APNs payloads are verified against Apple's current docs (date-stamped in `server/src/apns.ts`).

**Push-to-start (ActivityKit, iOS 17.2+)** — fully implemented. iOS observes `Activity<ZeroZeroWidgetActivityAttributes>.pushToStartTokenUpdates` from `didFinishLaunchingWithOptions`, registers via `POST /v1/live-activities/register-start-token`. The backend's `POST /v1/live-activities/start` sends the start event to all registered devices and falls back to the pending-queue path if no token is registered (or if the APNs delivery fails). End-to-end verification needs `.p8` credentials configured on the Worker.

**WidgetKit `pushHandler` (iOS 26+)** — fully implemented. Each widget configuration calls `.pushHandler(ZeroZeroWidgetPushHandler.self)`. The handler runs in the widget extension when iOS issues a push token, writes the per-kind token into the App-Group-shared `WidgetPushTokenStore`, and the host app picks up + registers each token via `POST /v1/widgets/register-push-token` on next launch. Backend pushes carry `aps.content-changed: true`, which iOS responds to by reloading the matching widget timelines. End-to-end verification also needs `.p8` credentials.

## License

MIT — see [LICENSE](./LICENSE).
