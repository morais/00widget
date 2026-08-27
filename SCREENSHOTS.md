# Marketing screenshots

The marketing screenshot suite is driven by XCUITest and uses built-in sample data. The iOS run fixes the status bar at 9:41 with full signal and battery, hides the `SAMPLE` indicators, and prepares dedicated Home Screen pages so repeated runs produce the same layouts.

## iPhone with Dynamic Island

This is the primary iPhone set. The default capture device is **iPhone 17 Pro**, and the files are written to `ios/build/screenshots/iphone-6.3/` at 1206×2622.

Run the full capture with:

```sh
ios/scripts/capture-screenshots.sh
```

The test captures these surfaces in order:

| File | Surface |
| --- | --- |
| `screenshot-widgets.png` | The in-app Widgets dashboard with the Solar, Washer, Boiler, and other sample cards. |
| `screenshot-insights.png` | The in-app chart section centered on the 30-day Energy and 20-run Deploys cards. |
| `screenshot-breakdown.png` | The in-app Device fleet breakdown, with status-colored Healthy, Updating, Attention, and Offline segments. |
| `screenshot-activities.png` | The in-app Activities screen with a 24-reading green home-battery curve that rises and dips with solar input and household load, currently ending at 95%. |
| `screenshot-home-dynamic-island.png` | The Home Screen with the compact battery Live Activity, three small Solar, Washer, and Boiler widgets, and a wide Energy chart. |
| `screenshot-home-widgets.png` | The same Home Screen after a long press expands the Dynamic Island Live Activity. This is the Home Screen image in the canonical published set. |
| `screenshot-home-insights.png` | A second Home Screen layout with a large 30-day Energy widget and small Deploys and Device fleet widgets. |

The compact Dynamic Island image is retained as an additional capture. The canonical copy command publishes the other six iPhone images:

```sh
ios/scripts/copy-screenshots.sh --set iphone-6.3 --to /path/to/site/public/assets
```

For a quick Activities-only refresh, run `ios/scripts/capture-screenshots.sh --only activities`. Use `--only app` to capture the four in-app surfaces without rebuilding or depending on a SpringBoard widget layout.

The subscription QA suite is separate from the public product-page set. Run
`ios/scripts/capture-screenshots.sh --only subscriptions` to capture the free,
trial, active, billing-retry, grace-period, expired, and publishing-paused
states under `ios/build/screenshots/iphone-6.3/subscriptions/`. The command runs both the
paywall-state test and the dashboard notice test; keep both filters when
changing this mode.

Both capture scripts keep incremental DerivedData under the gitignored `ios/build/` directory. Delete the corresponding `ScreenshotDerivedData-*` directory only when a clean rebuild is intentional; normal iterative runs should reuse it.

## Apple TV

Apple TV has a separate, native 1920×1080 suite using the **Apple TV 4K (3rd generation) (at 1080p)** simulator. Run it with:

```sh
ios/scripts/capture-tv-screenshots.sh
```

It writes the following files to `ios/build/screenshots/tvos/`:

| File | Surface |
| --- | --- |
| `screenshot-tv-widgets.png` | The general dashboard with the Solar and other classic cards. |
| `screenshot-tv-insights.png` | The insights dashboard with Energy, Deploys, Device fleet, and the running home battery activity. |
| `screenshot-tv-activities.png` | The Live Activities dashboard with the green home-battery curve rising and dipping before ending at 95%. |

Refresh only the Live Activities image with `ios/scripts/capture-tv-screenshots.sh --only activities`. Copy the full set with `ios/scripts/copy-screenshots.sh --set tvos --to /path/to/site/public/assets/tvos`.

## iPhone without Dynamic Island

The App Store 6.5-inch set contains the same four in-app screenshots plus
`screenshot-home-widgets.png`, showing the classic Home Screen layout without a
Dynamic Island. Capture the full marketing suite with an explicit device; do
not use `--only app`, because that mode intentionally omits the required Home
Screen image:

```sh
ios/scripts/capture-screenshots.sh \
  --device "iPhone 14 Plus – App Store 6.5" \
  --out build/screenshots/iphone-6.5
```

The canonical published order is Widgets, Home Screen widgets, Activities,
Insights, and Breakdown. The full run may produce additional Home Screen
captures, but only `screenshot-home-widgets.png` belongs to this App Store set.
`--out` is resolved from `ios/`, so do not prefix that value with `ios/`.
Copy it with `ios/scripts/copy-screenshots.sh --set iphone-6.5 --to
/path/to/site/public/assets`.

## iPad

iPad captures the same four in-app surfaces plus the classic and insights Home Screen layouts. Because iPad has no Dynamic Island, `screenshot-home-widgets.png` is the ordinary Home Screen with three small widgets and the wide Energy chart rather than an expanded Live Activity, and no `screenshot-home-dynamic-island.png` is created. The standard App Store run uses `ios/scripts/capture-screenshots.sh --device "iPad Pro 13-inch (M4)"`, writes 2064×2752 files to `ios/build/screenshots/ipad/`, and can be copied with `ios/scripts/copy-screenshots.sh --set ipad --to /path/to/site/public/assets/ipad`.

## App Store Connect

The screenshot root contains one directory per App Store device class and no
PNG files directly inside it:

```text
ios/build/screenshots/
├── iphone-6.3/
├── iphone-6.5/
├── ipad/
└── tvos/
```

After all four device sets pass visual QA, preview the replacement plan with:

```sh
ios/scripts/upload-appstore-screenshots.py --dry-run
```

Run the same command without `--dry-run` to publish the canonical iPhone,
6.5-inch iPhone, iPad, and Apple TV sets. The helper stages and waits for every
new asset before deleting an old one, then applies the marketing order declared
in the script. It uses the App Store Connect credentials documented for
`upload-testflight.sh`; the API key must have permission to manage app metadata.

## Implementation source

The capture behavior and attachment names live in `ios/UITests/ScreenshotTests.swift` and `ios/TVUITests/TVScreenshotTests.swift`. The entry points are `ios/scripts/capture-screenshots.sh`, `ios/scripts/capture-tv-screenshots.sh`, `ios/scripts/copy-screenshots.sh`, and `ios/scripts/upload-appstore-screenshots.py`.
