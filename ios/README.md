# 00Widget — iOS

SwiftUI app, WidgetKit extension, and Live Activity for iOS 18+.

## Prerequisites

- macOS with Xcode 16 or later
- An iOS 18 simulator or a real device running iOS 18+
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
2. Change the app and extension bundle ids (**`PRODUCT_BUNDLE_IDENTIFIER`**) from `com.example.zerowidget*` to a reverse-DNS prefix your team owns.
3. Replace the **App Group** `group.com.example.zerowidget` with one your team owns — it appears **three times** in `project.yml`:
   - `targets.ZeroWidgetApp.entitlements.properties.com.apple.security.application-groups`
   - `targets.ZeroWidgetApp.info.properties.ZWAppGroupIdentifier`
   - `targets.ZeroWidgetWidgets.entitlements.properties.com.apple.security.application-groups`
   - `targets.ZeroWidgetWidgets.info.properties.ZWAppGroupIdentifier`

   `Constants.swift` reads the App Group from `Info.plist` at runtime via the `ZWAppGroupIdentifier` key, so you don't have to edit any Swift sources.

4. Generate the Xcode project:

```
xcodegen
open ZeroWidget.xcodeproj
```

Re-run `xcodegen` any time you add/move files or change `project.yml`. The `.xcodeproj`, both `Info.plist` files, and both `.entitlements` files are gitignored — they're all regenerated from `project.yml`.

In Xcode, open *Signing & Capabilities* on both the app and widget targets, confirm **App Groups** points at your App Group, and **Push Notifications** is enabled on the app target.

If `project.yml.sample` ever gets updated upstream, re-merge into your local `project.yml` (or re-copy and re-apply your edits).

## Branding

The brand sheet and usage rules live in `docs/brand/`. Tagline is "Widgets for all your agents." — keep this exact wording.

The 1024 app icon is wired in at `ios/Resources/App/Assets.xcassets/AppIcon.appiconset/Icon-1024.png`. To regenerate it, re-export from `docs/brand/mark.svg` (opaque background — iOS rejects transparent app icons).

## Targets

- **ZeroWidgetApp** — SwiftUI app with four tabs: Dashboard, Activities, Settings, Debug.
- **ZeroWidgetWidgets** — widget extension containing four widget kinds (`Metric`, `Status`, `List`, `Progress`) and the Live Activity (`ZeroWidgetLiveActivityWidget`).

The shared Swift sources (`Sources/Shared/`) are compiled into both targets as source files rather than a framework — keeps the extension small and avoids dynamic-linking overhead.

## Running

Pick an iOS 18 device/simulator and run the **ZeroWidgetApp** scheme. On first launch:

1. Go to the **Settings** tab and enter a server base URL and API key. You can also just use the **Generate sample cards** button on the Dashboard to try widgets without a backend.
2. Add a 00Widget widget from the Home Screen or Lock Screen — long-press an empty area → **Edit** → **Add Widget** → search for *00Widget*.
3. In the Activities tab, tap **Start sample activity** to see the Live Activity on the Lock Screen / Dynamic Island.

### Building for the simulator without an Apple Developer team

```
ios/scripts/build-sim.sh --launch --base-url https://your-worker.workers.dev
```

That script handles the signing/entitlements quirks that prevent App Groups from working on sim builds without a configured Team ID. See AGENTS.md for the underlying reasoning.

## APNs

The iOS app **does not** hold the APNs private key. It only:

- Registers its APNs device token with the backend (`POST /v1/devices/register`).
- Observes `Activity.pushTokenUpdates` and registers the per-activity token (`POST /v1/live-activities/register`).
- Will register a widget push token with the backend (`POST /v1/widgets/register-push-token`) once wired through `WidgetConfiguration.pushHandler` — see the `TODO(apns)` in `MetricWidget.swift`.

The APNs `.p8` key lives only on the backend. See `server/README.md`.

## Troubleshooting

- **Widget is empty** — confirm the app has generated/fetched cards and the App Group is set correctly on *both* targets with matching entitlements.
- **Live Activity won't start** — confirm `NSSupportsLiveActivities` is `YES` in `Info.plist` and that the user hasn't disabled them in Settings → Face ID & Passcode → Live Activities (or device-level Settings → Live Activities).
- **Push token never arrives** — on simulator APNs is sandboxed; prefer a real device for end-to-end testing.
