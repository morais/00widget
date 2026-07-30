# 00Widget — Apple platforms

SwiftUI apps for iOS and tvOS 26+, plus the iOS WidgetKit extension and Live Activity.

## Prerequisites

- macOS with Xcode 26 or later
- An iOS/tvOS 26 simulator or a compatible real device
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- An Apple Developer account (required for App Groups, APNs, and running on device)

## First-time setup

`project.yml` is gitignored — it holds per-developer values (Team ID, bundle ids, App Group). The committed source-of-truth is `project.yml.sample`.

```
cd ios
cp project.yml.sample project.yml
```

Then edit `project.yml`:

1. Change **`DEVELOPMENT_TEAM`** under `settings.base` to your Apple Developer Team ID.
2. Change the app, extension, and TV bundle ids (**`PRODUCT_BUNDLE_IDENTIFIER`**) from `com.example.zerozerowidget*` to identifiers your team owns. The iOS and tvOS app targets use the same bundle id for the multi-platform App Store record.
3. Replace the **App Group** `group.com.example.zerozerowidget` with one your team owns — it appears **four times** in `project.yml`:
   - `targets.ZeroZeroWidgetApp.entitlements.properties.com.apple.security.application-groups`
   - `targets.ZeroZeroWidgetApp.info.properties.ZWAppGroupIdentifier`
   - `targets.ZeroZeroWidgetWidgets.entitlements.properties.com.apple.security.application-groups`
   - `targets.ZeroZeroWidgetWidgets.info.properties.ZWAppGroupIdentifier`

   `Constants.swift` reads the App Group from `Info.plist` at runtime via the `ZWAppGroupIdentifier` key, so you don't have to edit any Swift sources.

4. Replace the shared **Keychain access group** `$(AppIdentifierPrefix)com.example.zerozerowidget` if you changed the bundle id prefix. The app stores the API key there so widget App Intents can run safe actions.

5. Generate the Xcode project:

```
xcodegen
open ZeroZeroWidget.xcodeproj
```

Re-run `xcodegen` any time you add/move files or change `project.yml`. The `.xcodeproj`, generated `Info.plist` files, and generated `.entitlements` files are gitignored — they're all regenerated from `project.yml`.

In Xcode, open *Signing & Capabilities* on both the app and widget targets, confirm **App Groups** points at your App Group, and **Push Notifications** is enabled on the app target.

If `project.yml.sample` ever gets updated upstream, re-merge into your local `project.yml` (or re-copy and re-apply your edits).

## Branding

The brand sheet and usage rules live in `docs/brand/`. Tagline is "Widgets for all your agents." — keep this exact wording.

The 1024 app icon is wired in at `ios/Resources/App/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`. To regenerate it, re-export from `docs/brand/mark.svg` (opaque background — iOS rejects transparent app icons).

## Targets

- **ZeroZeroWidgetApp** — SwiftUI app with four tabs: Dashboard, Activities, Settings, Debug.
- **ZeroZeroWidgetWidgets** — widget extension containing the single-card widget, the grid widget, and the Live Activity (`ZeroZeroWidgetLiveActivityWidget`).
- **ZeroZeroWidgetTV** — Apple TV dashboard with Sign in with Apple and automatic card refresh.

The shared Swift sources (`Sources/Shared/`) are compiled into each target as source files rather than a framework — this keeps the extension small and avoids dynamic-linking overhead.

## Running

Pick an iOS 26 device/simulator and run the **ZeroZeroWidgetApp** scheme. On first launch:

1. Go to the **Settings** tab and enter a server base URL and API key. You can also just use the **Generate sample cards** button on the Dashboard to try widgets without a backend.
2. Add a 00Widget widget from the Home Screen or Lock Screen — long-press an empty area → **Edit** → **Add Widget** → search for *00Widget*.
3. Ask an agent to call `POST /v1/live-activities/start`. The Live Activity starts remotely and appears automatically on the Lock Screen / Dynamic Island.

For Apple TV, pick a tvOS 26 device/simulator and run the **ZeroZeroWidgetTV** scheme. Sign in with Apple, then the app fetches the tenant's cards and refreshes every 30 seconds.

For TestFlight, update `CURRENT_PROJECT_VERSION` only in the gitignored local `project.yml`, regenerate with `xcodegen`, and archive `ZeroZeroWidgetApp` and `ZeroZeroWidgetTV` separately. The exact archive, version-verification, and upload commands are documented in `AGENTS.md`.

### Building for the simulator without an Apple Developer team

```
ios/scripts/build-sim.sh --launch --base-url https://your-worker.workers.dev
```

That script handles the signing/entitlements quirks that prevent App Groups from working on sim builds without a configured Team ID. See AGENTS.md for the underlying reasoning.

## APNs

The iOS app **does not** hold the APNs private key. It only:

- Registers its APNs device token with the backend (`POST /v1/devices/register`).
- Registers the current push-to-start token and observes token rotation.
- Observes `Activity.activityUpdates` so remotely started activities register their per-activity push tokens (`POST /v1/live-activities/register`).
- Replays current start/activity tokens after login or configuration changes.
- Persists WidgetKit token/configuration snapshots through `WidgetConfiguration.pushHandler`, registers them immediately when the extension gets enough runtime, and reconciles through `WidgetCenter.currentPushInfo` at launch and on later foregrounds. If configured widgets appear before WidgetKit finishes generating `currentPushInfo`, the app uses a bounded 1/2/4/8/16-second bootstrap retry; it does not poll card data.
- After a successful foreground card fetch, saves the App Group cache and explicitly reloads both widget kinds so the visible widget catches up while the app is active instead of waiting for its background timeline budget.
- Shares the runtime server URL and stable device id through the App Group so the app and widget extension always register and fetch against the same account.

The APNs `.p8` key lives only on the backend. See `server/README.md`.

## Troubleshooting

- **Widget is empty** — confirm the app has generated/fetched cards and the App Group is set correctly on *both* targets with matching entitlements.
- **Live Activity won't start** — confirm `NSSupportsLiveActivities` is `YES` in `Info.plist` and that the user hasn't disabled them in Settings → Face ID & Passcode → Live Activities (or device-level Settings → Live Activities).
- **Push token never arrives** — on simulator APNs is sandboxed; prefer a real device for end-to-end testing.
