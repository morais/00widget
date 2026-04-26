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
- `docs/brand/README.md` — logo, colors, tagline rules.

## Status

All seven milestones scaffolded. Code paths that require real APNs credentials or Apple-docs-verified payload shapes are marked `TODO(apns):` so they can be finalized against the latest ActivityKit / WidgetKit documentation.

## License

MIT — see [LICENSE](./LICENSE).
