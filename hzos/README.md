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

The UI is Meta's **VR UI Set SDK for Compose** (`metavrx.uiset`, through the
metavrx BOM): theme, type, cards, buttons, dialogs, icons and the Settings
side rail. There is no Material layer. The Horizon Platform SDK supplies
sign-in and in-app purchase; nothing else from Meta is linked.

Multi-panel needs no SDK: activities launch into their own panels with task
flags (`ui/PanelLauncher.kt`).

## Layout

```
hzos/
  settings.gradle.kts  build.gradle.kts (Spotless)  .editorconfig (ktlint)
  app/build.gradle.kts  app/proguard-rules.pro  gradle/libs.versions.toml
  app/src/main/
    AndroidManifest.xml     # one activity per panel + <layout> sizes
    java/com/zerozerowidget/hzos/
      ZeroZeroWidgetApp.kt  # composition root (no DI), authedApi(), poll gating
      DashboardActivity.kt  # launcher panel: activities + cards
      CardDetailActivity.kt # one card or activity per pop-out
      SettingsActivity.kt   # settings, sign-in, account (singleTask)
      auth/                 # Horizon Platform SDK: sign-in, IAP, account-switch guard
      data/
        Models.kt           # wire-model mirror — keep in lockstep (see below)
        ZeroWidgetApi.kt    # OkHttp client + WireJson
        DashboardRepository.kt  # serialised, credential-fenced 60s poll
        ConnectionStore.kt  # Worker URL + API key (DataStore)
        SampleStore.kt, SampleData.kt  # on-device demo deck
        DeviceAuth.kt, HorizonLogin.kt # sign-in flows
      ui/
        PanelLauncher.kt, PanelBreakpoints.kt, PanelPrefs.kt, PanelState.kt
        theme/Theme.kt      # UI Set theme, spacing scale, panel glass
        uiset/              # thin aliases over UI Set controls
        cards/              # template renderers, plots, containers, controls
        dashboard/          # dashboard, card detail, activity detail
        settings/           # one file per Settings section
        agent/              # connect-an-agent guide
  app/src/test/             # JVM + Robolectric tests, layout screenshots
```

## Panels

| Panel | Activity | Instances |
| ----- | -------- | --------- |
| Dashboard | `DashboardActivity` (launcher) | one |
| Settings | `SettingsActivity` (`singleTask`) | one, reused |
| Card or activity detail | `CardDetailActivity` (`MULTIPLE_TASK`) | one per pop-out |

Settings opens with `LAUNCH_ADJACENT | NEW_TASK` (reusing the open
instance). Pop-out adds `MULTIPLE_TASK`, so three popped-out cards sit side
by side as three panels. Each activity declares its default and minimum
size in the manifest `<layout>` element (minimum 320dp wide, which is the
Quest shell's real floor); the shell lets the user move and resize from
there. Layouts switch at the widths in `ui/PanelBreakpoints.kt`.

To add a panel type: add an activity + `<layout>` entry, and a launcher in
`PanelLauncher.kt` (singleton or multi-instance flags as appropriate).

## Data model lockstep

`data/Models.kt` mirrors `server/src/types.ts` and
`ios/Sources/Shared/Models/`. Adding a field to `DashboardCard` means editing
**all three** in the same change. Unknown template/status strings fall back
(`summary`/`unknown`) instead of failing the list decode — one newer-server
card must not blank the dashboard, same rule as the Swift decoders.
That fallback only works for a property with a default, because
`WireJson` coerces an unknown enum value to the default rather than
throwing — so every enum-typed field in `Models.kt` has one.
`WireDecodingTest` decodes every card the `examples/` scripts publish (all
nine templates) and checks the fallbacks; run it after touching the model.

Decoded but not drawn, as of this writing: a card's `icon` and
`statusIcon` (SF Symbol names, which Horizon has no glyph set for),
`priority` (the server already sorts by it), and the iOS "Needs you" badge
(`NeedsYouBadge` exists; the attention-status + action rule does not yet).

## Sample data

`data/SampleData.kt` ports iOS `SampleDataFactory`'s user-facing deck
field-for-field: the 7 `makeCards()` widgets (launch, production, trials,
support, AI spend, agent runs, open PRs) plus both demo Live Activities
(app launch, screenshot capture), all under the reserved `sample-` id
namespace. The home-energy set and timeline fixture are excluded on
purpose, matching iOS — they belong to other campaigns, not the default
deck.

Samples are generated on-device into `SampleStore` (app-private DataStore,
survives relaunch), never published, and render alongside server cards
with a SAMPLE badge. Their buttons don't run — demo actions address
nothing. "Generate sample widgets" works offline with no account, and
"Clear samples" removes cards and demo activities together.

## Setup

1. Quest 3/3S/Pro with developer mode + USB debugging (Meta Horizon phone
   app → Devices → Developer Mode; headset Settings → System → Developer).
2. `cd hzos && ./gradlew :app:assembleDebug` (wrapper is committed; needs a
   JDK 17+ and the Android SDK).
3. `metavr adb install -r app/build/outputs/apk/debug/app-debug.apk`, launch
   00Widget from the library, and press Sign in (or Try demo data, which
   needs no account). The Worker URL comes from gitignored
   `hzos/defaults.properties` (copy from `defaults.properties.sample`);
   sign-in needs a Horizon Platform app ID in gitignored
   `hzos/local.properties` as `platformAppId=...`, and without one Settings
   says so instead of offering it. The ID is public, not a secret.

Polling is every 60s while a panel is on screen, and not at all otherwise,
plus a manual refresh. Panels have no WidgetKit-style reload budget, but
the server's rate limits still apply, so don't shorten the interval
without a reason.

## Sign-in: Meta identity, phone approval to join

There is no token to paste. Sign-in proves the headset's Meta account to
the Worker and gets a Horizon credential back (`data/HorizonLogin.kt`,
`data/DeviceAuth.kt`, `ui/settings/HorizonSignInSection.kt`):

1. The Platform SDK supplies the app-scoped Meta user id and a single-use
   proof nonce; the headset `POST`s both to `/v1/auth/horizon`.
2. A returning Meta account gets a token straight back. An unknown one is
   asked to choose: create a new 00Widget account, or join the one it
   already has through the iPhone app.
3. Joining answers with an RFC 8628 device code. The headset hands its
   `verification_uri_complete` to `Users().sendAuthUrl`, so the OS confirms
   and pushes the link to the Meta Horizon phone app; the operator approves
   in the 00Widget iPhone app (or the Worker's web page), and the headset
   polls `POST /v1/auth/device/token` until it is approved.

The token is an `app` credential (`zwa_`) with the `horizonApp` preset
(`read`, `publish`, `device:register`, `actions:run`). Being kind `app`,
it also reaches the account's app-only routes: deleting the account,
rotating agent tokens, approving devices. So it never leaves the headset.
It is stored encrypted in `ConnectionStore` together with the Meta id it
was issued for; a later Meta account switch on the headset clears it, and
while the current Meta user can't be read the app withholds the session's
data (`auth/MetaUserGuard.kt`).

Agent config hands agents a separate publisher token (`read`, `publish`,
`webhook:manage`), stored alongside as `agentKey`. It comes from sign-in
when the Worker issues one (`publisherCredential`), or from Rotate agent
token, which also revokes every earlier agent token. If `send_auth_url`
cannot run, the code and URL are shown for manual entry on the phone.
`cd ../server && npm test` covers the Worker side
(`server/src/deviceAuth.ts`, `server/src/horizonIdentity.ts`).

## Publishing to the Horizon Store

In-repo readiness is done; the rest is portal work:

Done in the tree:

- Reverse-DNS app id from gitignored `defaults.properties`
  (`com.zerozerowidget.hzos`; `com.example.*` never ships).
- Brand adaptive icon (`ic_launcher`, round variant) generated from
  `docs/brand/mark-transparent-1024.png` over deep navy.
- `allowBackup=false` so bearer tokens never enter cloud backups.
- No build carries a credential: the API key only ever comes from
  sign-in. The production Worker URL is embedded — it is public.
- Cleartext HTTP is blocked (targetSdk 34 default; there is no network
  security config and no localhost exception).
- Release is minified with R8 (`proguard-rules.pro`) and ships arm64 only.
- minSdk 32 / targetSdk 34 (compileSdk 36), panels with default + min sizes.

To cut a submission build (all secrets in gitignored `store.properties`,
copied from `store.properties.sample` — same pattern as the other
per-developer files; env vars override the file for CI):

1. `keytool -genkeypair -keystore ~/secure/00widget.jks -alias upload -keyalg RSA -keysize 2048 -validity 9125` (outside the repo, back it up — losing it means a new app listing) and record the paths/passwords plus `META_APP_SECRET` (Dashboard → app → API tab) in `store.properties`.
2. Nothing to bump: `versionCode` is the build's UTC hour (`yyyyMMddHH`), so it rises on its own. `upload-store.sh` refuses a second upload within the same hour, which the store would otherwise reject after the upload.
3. `scripts/upload-store.sh --channel ALPHA --age-group MIXED_AGES --notes "…"` — builds the signed release and uploads it. Channels `ALPHA`/`BETA`/`RC` test; `STORE` is production.
4. Developer portal: listing copy + screenshots, content-rating
   questionnaire, privacy policy URL (kept in gitignored `store.properties`
   as `PRIVACY_URL`), review access notes (sample deck works offline; hand
   reviewers a demo `device`-preset key for live data, revokable after
   review).

## Verification

```
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:verifyRoborazziDebug :app:lintDebug :app:detekt spotlessCheck
```

- Unit tests are JVM and Robolectric: repository ordering and polling,
  wire decoding against `examples/`, sample store, time and chart helpers.
- `verifyRoborazziDebug` compares every panel at 320, 360, 400, 728 and
  1280dp against `app/src/test/screenshots`. After an intended layout
  change, `recordRoborazziDebug` and look at the new PNGs before committing
  them. It proves layout only — check Look and Pinch, resizing and
  passthrough on a headset.
- `spotlessCheck` fails on formatting drift; `spotlessApply` fixes it.
- Lint and detekt fail on anything new; what existed when they were
  introduced is in `app/lint-baseline.xml` and `app/detekt-baseline.xml`,
  to be burned down. Regenerate a baseline only after fixing entries.
- `cd ../server && npm test` covers the device-code endpoints this app reads.

### Look and Pinch on the Spatial Simulator

Meta Spatial Simulator 207 (`metavr`) runs the app under Look and Pinch,
the Meta VR Glasses input model, by default. Check each change to a
panel's controls there:

1. `./gradlew :app:assembleDebug`, then
   `metavr -d emulator-5554 adb install -r app/build/outputs/apk/debug/app-debug.apk`.
2. The app should start without a "Switch to Controllers" prompt.
3. Simulator **Settings** → **Show Interactive Elements** outlines every
   element the system can target. Every button, card headline and chart
   should be outlined, nothing decorative, and no two outlines should
   overlap.
4. `scripts/lookpinch-audit.py -d emulator-5554 480 1280` measures every
   target in dp (one width per open window, topmost first; the widths are
   in `metavr shell dumpsys activity activities`) and fails on any under
   48dp or overlapping. Tap by label rather than coordinates:
   `metavr ui tap --content-desc Settings`.

The simulator opens every new window on top of the last one: it shows
one app in front and up to three behind, with no room to lay panels out
side by side. On a headset the same panels open beside each other
(`FLAG_ACTIVITY_LAUNCH_ADJACENT` in `ui/PanelLauncher.kt`), so judge
window placement there, not on the simulator.

For the Glasses' narrower field of view, `metavr device fov-sim enable`
crops a Quest 3, 3S or Pro to 70° × 66° until reboot; judge it through
the lenses, since captures before Horizon OS v209 don't show the crop.
