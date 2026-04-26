<p align="center">
  <img src="./docs/brand/wordmark-horizontal.png" alt="00Widget — Widgets for all your agents." width="640">
</p>

# 00Widget

**Widgets for all your agents.**

A reusable iOS companion app and Cloudflare Worker backend that lets your web apps, automations, and agents publish structured state to iOS Home/Lock Screen widgets, Live Activities, and the Dynamic Island.

The server never sends UI — only structured state conforming to a small set of templates. The iOS app renders that state through predefined SwiftUI views.

## Anatomy

```
00widget/
  ios/          # SwiftUI app + WidgetKit extension + Live Activity (iOS 18+)
  server/       # Cloudflare Worker (TypeScript) — REST API + APNs fan-out
  examples/     # curl scripts showing how any agent can publish state
```

## Quick start

### 1. Backend

```
cd server
npm install
cp .dev.vars.example .dev.vars   # fill in API_KEYS; leave APNS_* blank for local
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

Requires macOS with Xcode 16+, iOS 18 simulator or device, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
brew install xcodegen
cd ios
xcodegen
open ZeroZeroWidget.xcodeproj
```

In Xcode, change the bundle id and App Group to values your Apple Developer team owns (see `ios/README.md`), then run.

## Data model

See `ios/Sources/Shared/Models/` (Swift) and `server/src/types.ts` (zod) — the two are kept in lockstep.

- **DashboardCard** — a single widget tile. Templates: `metric`, `status`, `progress`, `timer`, `list`, `action`.
- **LiveActivitySession** — a Lock Screen / Dynamic Island activity.
- **ActionDefinition** — a button that runs a backend-defined action via `POST /v1/actions/:id/run`.

## Documentation

- `ios/README.md` — Xcode setup, entitlements, signing.
- `server/README.md` — Worker deploy, KV binding, APNs secrets.
- `examples/README.md` — publishing state from any shell or agent.
- `docs/INTEGRATION.md` — for agents (Claude Code / Codex) integrating *another* project with 00Widget.
- `docs/brand/README.md` — logo, colors, tagline rules.

## Pointing an agent at 00Widget from another project

If you're inside another repo (say, a CI pipeline or a home-automation script) and want to make Claude Code / Codex publish state to your 00Widget instance, paste this into the agent — it's self-contained:

```
Integrate this project with 00Widget so its state shows up on iOS widgets and Live Activities.

Read the integration contract: https://github.com/morais/00widget/blob/main/docs/INTEGRATION.md
That single document is everything you need — don't pull in the rest of the 00Widget repo.

Operator-supplied env vars:
  00WIDGET_BASE_URL=https://<their-worker>.workers.dev
  00WIDGET_API_KEY=<bearer token>

Verify both work with `curl $00WIDGET_BASE_URL/health` and an authenticated `GET /v1/cards` before writing any code.

Then:
1. Identify the surfaces in this project that an iOS widget should reflect (status, build state, queue depth, in-progress jobs, etc.).
2. For each, pick a template (metric/status/progress/list/action) per INTEGRATION.md's decision matrix.
3. Add the smallest possible publish path — a single function that POSTs to /v1/cards/upsert with a stable `id`. No SDK, no class hierarchy.
4. If something is time-bounded with a clear end (a build, a charge cycle, a delivery), use a Live Activity instead of a card.

Constraints:
- Use a stable `id` per logical thing — never embed timestamps or run ids.
- Never put secrets or PII in card fields. They render on the Lock Screen.
- Always end Live Activities. Never make destructive actions auto-run from widgets.
- Don't publish more than ~once a minute per card unless the value actually changed.
```

## Status

Working end-to-end. Cards publish, Live Activities start/update/end, push-to-start is wired, and APNs payloads are verified against Apple's current docs (date-stamped in `server/src/apns.ts`).

**Push-to-start (ActivityKit, iOS 17.2+)** — fully implemented. iOS observes `Activity<ZeroZeroWidgetActivityAttributes>.pushToStartTokenUpdates` from `didFinishLaunchingWithOptions`, registers via `POST /v1/live-activities/register-start-token`. The backend's `POST /v1/live-activities/start` sends the start event to all registered devices and falls back to the pending-queue path if no token is registered (or if the APNs delivery fails). End-to-end verification needs `.p8` credentials configured on the Worker.

**WidgetKit `pushHandler`** — turned out to be **iOS 26+** in the Xcode 26 SDK, not iOS 18 as the docs implied. Server-side (`sendWidgetReloadPush` with `aps.content-changed: true`) and the App-Group token bridge (`WidgetPushTokenStore`, `AppEnvironment.registerPendingWidgetTokens`) are in place. To activate, bump `IPHONEOS_DEPLOYMENT_TARGET` to `26.0` in `project.yml.sample`, write a `WidgetPushHandler` conformer that calls `WidgetPushTokenStore.record(...)`, and append `.pushHandler(YourHandler.self)` to each widget — the comment in `MetricWidget.swift` walks through it. iOS 18 fallback is timeline refresh every 15 minutes.

## License

MIT — see [LICENSE](./LICENSE).
