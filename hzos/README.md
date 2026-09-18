# 00Widget for Horizon OS (`hzos`)

A Meta Horizon OS **panel app** that renders the same 00Widget Worker state
as the iOS app and Apple TV dashboard — cards and Live Activity sessions —
as shell panels you can arrange around you.

The server never sends UI, only typed JSON (`docs/llms.md`). This app is a
third renderer of that state, next to SwiftUI (`ios/`) and the guest web page
(`server/src/guestPage.ts`).

## Stack: plain Android panels, no engine

Horizon OS runs ordinary 2D Android apps as floating shell panels (move,
resize, arrange — like Settings or the Browser). That is what this is: one
activity per panel, Jetpack Compose UI, no game engine, no Spatial SDK. (An
immersive Spatial SDK version was prototyped and removed — wrong app type
for a dashboard; see git history if curious.)

Multi-panel needs no SDK: activities launch into their own panels with task
flags (`ui/PanelLauncher.kt`).

## Layout

```
hzos/
  settings.gradle.kts  app/build.gradle.kts  gradle/libs.versions.toml
  app/src/main/
    AndroidManifest.xml   # one activity per panel + <layout> sizes
    java/com/example/zerozerowidget/hzos/
      ZeroZeroWidgetApp.kt   # composition root (no DI framework)
      DashboardActivity.kt   # launcher panel: card list
      ActivitiesActivity.kt  # Live Activities panel (singleton)
      ConnectionActivity.kt  # connection + phone sign-in (singleton)
      CardDetailActivity.kt  # one card's detail (one instance per pop-out)
      data/
        Models.kt            # wire-model mirror — keep in lockstep (see below)
        ZeroWidgetApi.kt     # OkHttp + kotlinx.serialization, read + safe actions
        DeviceAuth.kt        # RFC 8628 device-code client (server pending)
        ConnectionStore.kt   # base URL + API key (DataStore) until login lands
        DashboardRepository.kt  # StateFlow + 60s poll + manual refresh
      auth/HorizonAuth.kt    # send_auth_url delivery wrapper
      ui/
        PanelLauncher.kt     # singleton vs per-card launch flags
        theme/Theme.kt       # dark panel theme
        cards/CardViews.kt   # all 9 template renderers + hand-rolled sparkline
        dashboard/DashboardPanel.kt  # list + inline expand + pop-out + detail
        activities/ActivitiesPanel.kt
        settings/ConnectionPanel.kt
```

## Panels

| Panel | Activity | Instances |
| ----- | -------- | --------- |
| Dashboard | `DashboardActivity` (launcher) | one |
| Live Activities | `ActivitiesActivity` (`singleTask`) | one, reused |
| Connection | `ConnectionActivity` (`singleTask`) | one, reused |
| Card detail | `CardDetailActivity` (`MULTIPLE_TASK`) | one per popped-out card |

Dashboard/activities/settings open with `LAUNCH_ADJACENT | NEW_TASK`
(reuses the open instance). Card pop-out adds `MULTIPLE_TASK`, so three
popped-out cards sit side by side as three panels. Each activity declares
its default/min size in the manifest `<layout>` element; the shell lets the
user move and resize from there.

To add a panel type: add an activity + `<layout>` entry, and a launcher in
`PanelLauncher.kt` (singleton or multi-instance flags as appropriate).

## Data model lockstep

`data/Models.kt` mirrors `server/src/types.ts` and
`ios/Sources/Shared/Models/`. Adding a field to `DashboardCard` means editing
**all three** in the same change. Unknown template/status strings fall back
(`summary`/`unknown`) instead of failing the list decode — one newer-server
card must not blank the dashboard, same rule as the Swift decoders.

## Setup

1. Quest 3/3S/Pro with developer mode + USB debugging (Meta Horizon phone
   app → Devices → Developer Mode; headset Settings → System → Developer).
2. `cd hzos && ./gradlew :app:assembleDebug` (wrapper is committed; needs a
   JDK 17+ and the Android SDK).
3. `adb install -r app/build/outputs/apk/debug/app-debug.apk`, launch
   00Widget from the library. The Connection panel (⚙) arrives with the
   Worker URL pre-filled from gitignored `hzos/defaults.properties` (copy
   from `defaults.properties.sample`); paste a tenant API token with the
   `device` preset from the Worker's `/admin` page (`read` + `actions:run`
   — a `publisher` token 403s on action runs and needlessly grants `publish`
   + `webhook:manage`), Save + connect.

Polling is 60s + manual refresh — panels have no WidgetKit-style reload
budget, but the server's rate limits still apply, so don't shorten the
interval without a reason.

## Login: device flow via `send_auth_url` (client built, server pending)

The Connection panel offers "Sign in with phone" next to manual paste. It
implements the headset half of an OAuth Device Authorization Grant
(RFC 8628), delivered through the Horizon Login API:

1. Headset `POST`s the Worker for a device code (no auth).
2. Headset calls `Users().sendAuthUrl(verification_uri_complete)` (Horizon
   Platform SDK `users-kotlin`). The OS shows a confirmation dialog and
   pushes the URL to the Horizon mobile app, code pre-filled — no retyping
   a code you saw inside the headset.
3. Operator approves on the phone (see server contract below).
4. Headset polls until approval and stores the returned token in the same
   `ConnectionStore` keys manual paste uses. Nothing downstream changes.

Any failure — no Platform app ID, Platform SDK uninitialized, declined
dialog, older OS, server without the flow — degrades to showing the
`user_code` + `verification_uri` for manual entry, which doubles as the
required fallback where `send_auth_url` is unavailable.

Phone sign-in needs a Horizon Platform app ID (developer portal → your
app): put it in `hzos/local.properties` (gitignored) as
`platformAppId=...`. Empty means the button path is disabled and manual
paste is the only option. The ID is public, not a secret.

### Server stub contract (to build)

`data/DeviceAuth.kt` is written against this shape; requesting a code
against today's Worker 404s and the UI says so, falling back to paste.

- `POST /v1/auth/device/code` (no auth, strictly rate-limited) →
  `{device_code, user_code, verification_uri, verification_uri_complete?,
  expires_in, interval}`. Codes random per attempt, short TTL (~10 min),
  single-use. No PII in the URL query.
- Approval page at `verification_uri` (Worker-served, mobile browser):
  operator signs in with Apple via the existing `/login` web flow — which
  resolves an *existing* tenant and never creates one — then Approve/Deny
  binds the code to that tenant. Never take the tenant from the request.
- `POST /v1/auth/device/token` `{device_code}` → `{token}` once approved,
  else `{error: authorization_pending | slow_down | denied | expired}`.
  The token carries the **`device` preset** (`read`, `device:register`,
  `actions:run`) — never `publisher`.
- Codes are ephemeral with a TTL sweep (like `rate_limit_buckets`), so they
  stay out of the account-deletion table in `server/src/account.ts`.
  Brute-forceable user codes need strict attempt limits + short expiry.

## Publishing to the Horizon Store (later)

- Replace `com.example.zerozerowidget.hzos` with an owned reverse-DNS id;
  `com.example.*` is rejected at submission.
- Provide store icons, listing copy, privacy policy URL (the app talks to an
  operator-run Worker; say what it sends: bearer token + card reads).
- Keep `usesCleartextTraffic` off — release builds stay https-only; the
  http exception is localhost-shaped and validated in code.
- Declare data use: API key in app-private DataStore, never logged.
- Declare the `uses-horizonos-sdk` manifest stanza with the min version that
  carries the Login API, so the store gates installation instead of the app
  failing at runtime (manual-code fallback covers old OS, not a missing API).

## Verification

- `./gradlew :app:assembleDebug` (needs Android SDK; not runnable in this
  repo's iOS/Worker CI).
- After any template change: eyeball every renderer in `CardViews.kt` on
  device — same rule as iOS, the compiler can't see a clipped card.
- `cd ../server && npm test` still covers the API this app reads; this client
  adds no server surface.
