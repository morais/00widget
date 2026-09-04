# Marketing screenshots

The marketing screenshot suite is driven by XCUITest and uses built-in sample data. The iOS run fixes the status bar at 9:41 with full signal and battery, hides the `SAMPLE` indicators, and prepares dedicated Home Screen pages so repeated runs produce the same layouts.

## iPhone with Dynamic Island

This is the primary iPhone set. The default capture device is **iPhone 17 Pro**, and the raw files are written to `artifacts/screenshots/raw/iphone-6.3/` at 1206×2622.

Run the full capture with:

```sh
marketing/screenshots/capture-ios.sh
```

The test captures these surfaces in order:

| File | Surface |
| --- | --- |
| `screenshot-widgets.png` | The in-app Widgets dashboard with the Solar, Nightly run, Boiler, and other sample cards. |
| `screenshot-insights.png` | The in-app chart section centered on the 30-day Energy and 20-run Deploys cards. |
| `screenshot-activities.png` | The in-app Activities screen with a 24-reading green home-battery curve that rises and dips with solar input and household load, currently ending at 95%. |
| `screenshot-home-widgets.png` | The Home Screen with three small Solar, Nightly run, and Boiler widgets, a wide Energy chart, and the expanded Dynamic Island Live Activity. |
| `screenshot-home-insights.png` | A second Home Screen layout with a large 30-day Energy widget and small Deploys and Device fleet widgets. |
| `screenshot-home-metrics.png` | A third Home Screen layout with one large four-metric grid showing Solar, Car, Energy, and Deploys. |
| `screenshot-lock-activity.png` | The Lock Screen with the launch Live Activity, captured host-side via the Simulator accessibility adapter after XCUITest stages the activity. |

The canonical App Store set contains Home Screen widgets, Home Screen insights,
Home Screen metrics, Lock Screen activity, Widgets, Insights, and Activities,
in that order:

```sh
marketing/screenshots/copy.sh --set iphone-6.3 --to /path/to/site/public/assets
```

For a quick Activities-only refresh, run `marketing/screenshots/capture-ios.sh --only activities`. Use `--only app` to capture the three in-app surfaces without rebuilding or depending on a SpringBoard widget layout. Use `--only lock` to refresh just the Lock Screen surface: it reuses the built products, stages the launch Live Activity through a marker test, and locks the simulator host-side, so it needs macOS Accessibility permission for the terminal running it.

The subscription QA suite is separate from the public product-page set. Run
`marketing/screenshots/capture-ios.sh --only subscriptions` to capture the free,
trial, active, billing-retry, grace-period, expired, and publishing-paused
states under `artifacts/screenshots/raw/iphone-6.3/subscriptions/`. The command runs both the
paywall-state test and the dashboard notice test; keep both filters when
changing this mode.

Both capture scripts keep incremental DerivedData under the gitignored `ios/build/` directory. Delete the corresponding `ScreenshotDerivedData-*` directory only when a clean rebuild is intentional; normal iterative runs should reuse it.

A successful full iOS or tvOS capture also writes `.capture-manifest.json` inside that
device folder with the checksums produced by that exact XCUITest run. The export
fails if a required attachment is absent, including
`screenshot-home-widgets.png`; an older file left in the directory cannot make a
partial run look complete. App Store publishing requires this provenance by
default. `--allow-unprovenanced` exists only for an intentional one-time
migration of older assets.

## Apple TV

Apple TV has a separate, native 1920×1080 suite using the **Apple TV 4K (3rd generation) (at 1080p)** simulator. Run it with:

```sh
marketing/screenshots/capture-tvos.sh
```

It writes the following raw files to `artifacts/screenshots/raw/tvos/`:

| File | Surface |
| --- | --- |
| `screenshot-tv-insights.png` | The insights dashboard with Energy, Deploys, Device fleet, and the running home battery activity. |
| `screenshot-tv-widgets.png` | The general dashboard with the Solar and other classic cards. |
| `screenshot-tv-card-detail.png` | The Energy card's detail panel, which is what pressing Select on a card opens. |

The canonical App Store order is Insights, Widgets, then Card detail.

Each Apple TV capture is composed to fill the screen exactly once, so check a
new one against the bottom edge rather than trusting the full-size render. The
`widgets` section deliberately holds six of the eight samples: two rows is what
1080 lines hold at the card's height, and an image that slices a third row
through the middle of a number reads as a bug. The two it leaves out are the two
the insights capture features, so the set covers every sample without repeating
one. Copy the promotional set with `marketing/screenshots/copy.sh --set tvos --to /path/to/site/public/assets/tvos`.

## iPhone without Dynamic Island

The App Store 6.5-inch set follows the same seven-image story as the 6.3-inch set.
`screenshot-home-widgets.png` shows the classic Home Screen layout without a
Dynamic Island, and `screenshot-home-metrics.png` uses the same large
four-metric widget. Capture the full marketing suite with an explicit device;
do not use `--only app`, because that mode intentionally omits the required
Home Screen images:

```sh
marketing/screenshots/capture-ios.sh \
  --device "iPhone 14 Plus – App Store 6.5"
```

The canonical published order is Home Screen widgets, Home Screen insights,
Home Screen metrics, Lock Screen activity, Widgets, Insights, and Activities.
Relative `--out` paths are resolved from `ios/`; this canonical device already
selects the correct default. Copy the promotional set with:

```sh
marketing/screenshots/copy.sh --set iphone-6.5 --to /path/to/site/public/assets
```

## iPad

iPad follows the same seven-image story and order. Because iPad has no Dynamic Island, `screenshot-home-widgets.png` is the ordinary Home Screen with three small widgets and the wide Energy chart. Its `screenshot-home-metrics.png` uses a four-metric `systemExtraLarge` widget, the largest iPad family. The canonical published order is Home Screen widgets, Home Screen insights, Home Screen metrics, Lock Screen activity, Widgets, Insights, and Activities. The standard App Store run uses `marketing/screenshots/capture-ios.sh --device "iPad Pro 13-inch (M4)"`, writes 2064×2752 raw files to `artifacts/screenshots/raw/ipad/`, and can be copied from the promotional tree with `marketing/screenshots/copy.sh --set ipad --to /path/to/site/public/assets/ipad`.

## Promotional compositions

The XCUITest files above are raw captures and remain the provenance-backed
source material. Promotional compositions are generated into the separate
`artifacts/screenshots/promotional/` tree; never write them back into
`artifacts/screenshots/raw/` or replace a `.capture-manifest.json` checksum.

The approved visual treatment is an off-white editorial headline panel, a
short trend-teal rule, and the raw capture inside physical device chrome below
it. The device begins about one fifth of the way down the canvas, fills roughly
88% of its width, and deliberately runs past the bottom edge. That bottom crop
is part of the composition: do not shrink the device to reveal its complete
outline. The copy is identical on the 6.3-inch iPhone, 6.5-inch iPhone, and
iPad; only the hardware frame and layout scale for the device class.
The iPad uses the 13-inch iPad Pro's native 60 px framebuffer corner radius
and a uniform bezel matching the display-to-device width ratio; do not reuse
the much thinner iPhone bezel treatment.
The compositor also restores hardware that simulator screenshots omit. It uses
native iPhone 16 Pro coordinates for the 6.3-inch Dynamic Island and detects
whether SpringBoard already rendered a compact or expanded Live Activity before
adding the empty state. Every 6.5-inch screen uses the exact smaller iPhone 14
Plus notch silhouette from Xcode's bundled framebuffer mask.

The seven images tell one benefit-led story: see every agent, understand what is
moving, step in when needed, and turn updates into decisions. The Activities
image describes the in-app activity list; the Lock Screen image is the
dedicated system-surface capture, taken host-side after XCUITest stages the
launch activity.

| File | Headline | Supporting line |
| --- | --- | --- |
| `screenshot-home-widgets.png` | **Know what every agent is doing.** | Live progress, results, and approvals—right on your Home Screen. |
| `screenshot-home-insights.png` | **One dashboard. Every agent.** | See the work that’s done, in motion, and waiting on you. |
| `screenshot-home-metrics.png` | **Follow every step live.** | ETAs and changing work on the Lock Screen and Dynamic Island. |
| `screenshot-lock-activity.png` | **Live work, on the Lock Screen.** | Check progress at a glance — the update comes to you. |
| `screenshot-widgets.png` | **Step in at the right moment.** | Approve, retry, or open the exact task without hunting through chat. |
| `screenshot-insights.png` | **Updates become decisions.** | Trends, run history, breakdowns, and concise agent briefings. |
| `screenshot-activities.png` | **Every active job. One place.** | See what is running, current, and complete. |

Apple TV follows the same physical-device treatment with a landscape television
frame that extends past the right and bottom edges. The television uses square
screen corners and a very thin bezel; do not reuse the rounded tablet or phone
frame. Its three-image copy is:

| File | Headline | Supporting line |
| --- | --- | --- |
| `screenshot-tv-insights.png` | **Your agent control room.** | See every launch task, metric, and exception at a glance. |
| `screenshot-tv-widgets.png` | **Live work. Shared screen.** | Keep the whole room aligned without opening another dashboard. |
| `screenshot-tv-card-detail.png` | **The detail is one click away.** | Open any card for the trend, briefing, or action behind it. |

Generate all 24 promotional images from the current raw captures with:

```sh
python3.12 marketing/screenshots/generate-promotional.py
```

The canonical end-to-end workflow captures all four raw device sets and then
generates and verifies all 24 promotional compositions:

```sh
marketing/screenshots/capture-all.sh
```

Its `--verify-only` mode checks both trees and fails if a promotional image was
generated from an older raw capture.

Generate one device class while iterating with `--set iphone-6.3`,
`--set iphone-6.5`, `--set ipad`, or `--set tvos`. The output keeps the canonical filenames
inside device-specific directories and writes
`promotional-manifest.json` with source and output SHA-256 checksums. The
compositor validates the source dimensions before it writes anything.

The App Store upload helper reads the verified
`artifacts/screenshots/promotional/` directories. It refuses to publish by
default unless `promotional-manifest.json` proves that every composition was
generated from the current raw capture checksum.

## App Store Connect

The artifact root separates provenance-backed captures from the promotional
images distributed to App Store Connect and websites:

```text
artifacts/screenshots/
├── raw/
│   ├── iphone-6.3/
│   ├── iphone-6.5/
│   ├── ipad/
│   └── tvos/
└── promotional/
    ├── iphone-6.3/
    ├── iphone-6.5/
    ├── ipad/
    └── tvos/
```

The canonical localized listing copy lives in `ios/appstore-metadata.json`.
It covers the app-level `en-US` name and subtitle, and the iOS and tvOS
promotional text, keywords, and description for the marketing version in
`ios/project.yml`. That version must already exist for both platforms in App
Store Connect; the scoped metadata command does not create a release version.
Preview metadata drift without writing it with:

```sh
ios/scripts/sync-appstore-metadata.py --dry-run
```

Run the same command with `--apply` (or with no mode flag) to write only changed
fields; every write is immediately read back and verified. Use `--verify-only`
to fail on any remote drift. App Store Connect's API manages all five fields,
so there are currently no manual exceptions for this metadata scope. If a
future listing field cannot be managed by the API, document it here as a manual
exception instead of adding it to the command's claimed scope.

After all four device sets pass visual QA, preview the screenshot replacement
plan with:

```sh
ios/scripts/upload-appstore-screenshots.py --dry-run
```

Run the same command without `--dry-run` to publish the canonical iPhone,
6.5-inch iPhone, iPad, and Apple TV sets. The helper stages and waits for every
new asset that fits alongside the old set. For sets that would exceed Apple's
ten-image limit, it verifies the maximum safe batch before removing the old
assets and uploading the remainder. It then applies the marketing order declared
in the script. It uses the App Store Connect credentials documented for
`upload-testflight.sh`; the API key must have permission to manage app metadata.

After publishing, verify remote image count, content, and order against the
canonical local inventory:

```sh
ios/scripts/upload-appstore-screenshots.py --verify-only
```

This check is required before submission. In particular, it fails if the
6.5-inch set lacks `screenshot-home-widgets.png`; do not use the App Store
Connect website to assemble a screenshot set by hand.

To sync or verify the metadata, screenshots, and default App Clip card together,
use the single listing entry point. The App Clip invocation URL lives in the
gitignored `ios/appstore.env`, whose committed template is
`ios/appstore.env.sample`. Set `ZW_APPCLIP_INVOCATION_URL` only for a one-off
override:

```sh
cp ios/appstore.env.sample ios/appstore.env
# edit ios/appstore.env
ios/scripts/sync-appstore-listing.sh --dry-run
ios/scripts/sync-appstore-listing.sh --apply
ios/scripts/sync-appstore-listing.sh --verify-only
```

The command manages the app name, subtitle, promotional text, keywords, and
description; the App Clip action, `en-US` subtitle, App Review invocation URL,
and `docs/brand/app-clip-header.png`; and every screenshot set above. The App
Store Connect website is a visual inspection and emergency fallback, not a
listing-authoring step.

## Implementation source

The capture behavior and attachment names live in `ios/UITests/ScreenshotTests.swift` and `ios/TVUITests/TVScreenshotTests.swift`. The Lock Screen surface additionally uses `testCaptureLockScreenStaging` as a staging marker plus the host-side `marketing/screenshots/sim-lock-capture.sh` adapter, which locks the simulator through its accessibility menu and screenshots the framebuffer. Marketing entry points live together as `marketing/screenshots/capture-ios.sh`, `marketing/screenshots/capture-tvos.sh`, `marketing/screenshots/capture-all.sh`, `marketing/screenshots/generate-promotional.py`, and `marketing/screenshots/copy.sh`. App Store distribution remains in `ios/appstore-metadata.json`, `ios/scripts/sync-appstore-metadata.py`, `ios/scripts/upload-appstore-screenshots.py`, and `ios/scripts/sync-appstore-listing.sh` because it is release tooling rather than asset creation.
