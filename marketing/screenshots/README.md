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
| `screenshot-approve.png` | The Launch card's own screen with its Approve action and the confirmation alert the app puts in front of it. `approve-launch` carries `confirm: true`, so a widget tap cannot run it — this is the screen that rule routes to. |
| `screenshot-insights.png` | The bottom of the in-app deck: the AI spend budget, the 20-run Agent runs history, and Open PRs. Scrolled to the list's end rather than to a measured offset, so a change to the deck's length cannot move it. |
| `screenshot-share.png` | The guest-link sheet for the Launch card: the QR, what the code grants, and when it stops working. One half of the share frame. |
| `screenshot-clip.png` | The other half: the App Clip that same code opens, rendering the same Launch card read-only. Captured host-side — see below. |
| `screenshot-activities.png` | The in-app Activities screen with the App launch job at 4/5, one step waiting on a person and four finished. Composed for 00widget.com; not in the App Store sequence, which spends that slot on the share proof. |
| `screenshot-home-widgets.png` | The Home Screen with small Production, Open PRs, and Launch widgets, a wide Trials chart, and the **compact** Dynamic Island Live Activity. |
| `screenshot-island-expanded.png` | The same activity in the expanded Dynamic Island. Captured only on the 6.3-inch device, the only one with an Island, and composed as its own promotional frame — the phone's top seen close up, which is why that set ships eight images and the others seven. |
| `screenshot-home-insights.png` | A second Home Screen layout with a large Trials widget and small Agent runs and Support widgets. |
| `screenshot-home-metrics.png` | A third Home Screen layout with one large four-metric grid showing Trials, Support, Agent runs, and AI spend. |
| `screenshot-lock-activity.png` | The Lock Screen with the launch Live Activity, captured host-side via the Simulator accessibility adapter after XCUITest stages the activity. |

Two of those are captured host-side, because XCUITest has no way to reach
either surface. The Lock Screen is captured through the Simulator's
accessibility menu after XCUITest stages the activity. The App Clip is
captured by building, installing and launching it with `--guest-fixture`: a
clip is normally launched by an App Clip experience resolving an invocation
URL, a capture simulator has no such experience registered, and `simctl
openurl` on the link therefore opens Safari. The fixture resolves
`SampleDataFactory.marketingGuestToken` locally, and that is the same token
the app's QR encodes — the two halves of the share frame are one link rather
than two props. The clip uninstalls itself afterwards, because an installed
clip is an extra icon on the Home Screen and the Home Screen is three of this
run's images.

The canonical App Store set contains Home Screen widgets, Home Screen insights,
Lock Screen activity, Home Screen metrics, approval, Insights, and the share
proof, in that order — with the expanded Dynamic Island fourth on the 6.3-inch
set, the only capture device that has one:

```sh
marketing/screenshots/copy.sh --set iphone-6.3 --to /path/to/site/public/assets
```

For a quick Activities-only refresh, run `marketing/screenshots/capture-ios.sh --only activities`. Use `--only app` to capture the three in-app surfaces without rebuilding or depending on a SpringBoard widget layout. Use `--only island` for a 37-second look at the Dynamic Island — it stages the
launch activity, backgrounds the app, and captures the compact and expanded
presentations plus 2x zoomed crops to `artifacts/screenshots/probe/<device>/`.
Those are a diagnostic, never an App Store asset, which is why they live
outside the raw tree. The Island is system-drawn, so nothing cheaper can see
it; see the AGENTS.md section for what it can and cannot answer. Use `--only
lock` to refresh just the Lock Screen surface: it reuses the built products, stages the launch Live Activity through a marker test, and locks the simulator host-side, so it needs macOS Accessibility permission for the terminal running it.

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
moving, step in when needed, and turn updates into decisions. Each claim is made
on the frame that shows it — the Lock Screen and Dynamic Island are named on the
image of those surfaces, not on a Home Screen grid.

| File | Headline | Supporting line |
| --- | --- | --- |
| `screenshot-home-widgets.png` | **Know what every agent is doing.** | Live progress, results, and approvals—right on your Home Screen. |
| `screenshot-home-insights.png` | **One dashboard. Every agent.** | See the work that’s done, in motion, and waiting on you. |
| `screenshot-lock-activity.png` | **Follow every step live.** | Progress, completed steps, and the next decision—right on your Lock Screen. |
| `screenshot-island-expanded.png` (6.3-inch only) | **Keep live work in sight.** | Progress and approvals stay visible in the Dynamic Island. |
| `screenshot-home-metrics.png` | **Four agents. One widget.** | Trends, budgets, and run history—without opening anything. |
| `screenshot-approve.png` | **Step in at the right moment.** | Approve from the card—00Widget asks before anything runs. |
| `screenshot-insights.png` | **Updates become decisions.** | Spend against budget, run history, and what is still open. |
| `screenshot-share.png` + `screenshot-clip.png` | **Share live status—not another login.** | Anyone you send the code to sees the card, read-only, without an account. |

The share frame is the only two-device composition in the sequence, because it
is the only one making a two-step claim. The phones stand shoulder to
shoulder, touching but not overlapping: the QR sits in the middle of the first
screen, so *any* overlap from the right eats it, and a share frame whose code
is half covered proves nothing. The relationship is carried by a vertical
stagger instead. Two phones side by side can only be about half the canvas
wide, so they are about half its height too; the stagger spends some of that
slack and the rest is split above and below rather than pooled at the bottom.

`screenshot-activities.png` is still composed, for 00widget.com, but is not in
the App Store sequence — the share proof replaced it there.
`upload-appstore-screenshots.py` holds the storefront order, which is why that
list and `PROMOTIONS` are not the same list.

The hero shows the *compact* Island, because expanded it is drawn over the
first row of Home Screen widgets and covers their titles. The expanded
presentation gets its own frame rather than an inset over the Lock Screen one:
composed as an inset it showed the same four lines as the card beneath it,
which reads as one thing printed twice rather than as two surfaces. It is
drawn as the phone's top seen close up — bezel, status bar, Island and the
first rows of the Home Screen — because an Island cut out and floated on the
background reads as unfinished: it is a 3.25:1 pill in a 1:2.17 canvas, mostly
empty page at any size, and it loses the hardware that makes an Island legible.
A set whose capture device has no Island — 6.5-inch and iPad — simply omits the
frame.

The zoom has a ceiling: past full canvas width the phone's rounded top corners
leave the frame, and with them the thing that distinguishes an Island from a
black shape. The Island is centred, so it stays whole at any width; the corners
are what set the limit.

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
