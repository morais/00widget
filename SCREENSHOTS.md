# Marketing screenshots

The marketing screenshot suite is driven by XCUITest and uses built-in sample data. The iOS run fixes the status bar at 9:41 with full signal and battery, hides the `SAMPLE` indicators, and prepares dedicated Home Screen pages so repeated runs produce the same layouts.

## iPhone with Dynamic Island

This is the primary iPhone set. The default capture device is **iPhone 17 Pro**, and the files are written to `ios/build/screenshots/` at 1206×2622.

Run the full capture with:

```sh
ios/scripts/capture-screenshots.sh
```

The test captures these surfaces in order:

| File | Surface |
| --- | --- |
| `screenshot-widgets.png` | The in-app Widgets dashboard with the Solar, Washer, Boiler, and other sample cards. |
| `screenshot-insights.png` | The in-app chart section centered on the Energy and Deploys cards. |
| `screenshot-breakdown.png` | The in-app Spending breakdown card. |
| `screenshot-activities.png` | The in-app Activities screen with a running Washing machine Live Activity. |
| `screenshot-home-dynamic-island.png` | The Home Screen with the compact Live Activity in the Dynamic Island and the Solar, Washer, and Boiler widgets. |
| `screenshot-home-widgets.png` | The same Home Screen after a long press expands the Dynamic Island Live Activity. This is the Home Screen image in the canonical published set. |
| `screenshot-home-insights.png` | A second Home Screen layout with the Energy, Deploys, and Spending widgets. |

The compact Dynamic Island image is retained as an additional capture. The canonical copy command publishes the other six iPhone images:

```sh
ios/scripts/copy-screenshots.sh --to /path/to/site/public/assets
```

For a quick Activities-only refresh, run `ios/scripts/capture-screenshots.sh --only activities`. Use `--only app` to capture the four in-app surfaces without rebuilding or depending on a SpringBoard widget layout.

## Apple TV

Apple TV has a separate, native 1920×1080 suite using the **Apple TV 4K (3rd generation) (at 1080p)** simulator. Run it with:

```sh
ios/scripts/capture-tv-screenshots.sh
```

It writes the following files to `ios/build/screenshots/tvos/`:

| File | Surface |
| --- | --- |
| `screenshot-tv-widgets.png` | The general dashboard with the Solar and other classic cards. |
| `screenshot-tv-insights.png` | The insights dashboard with Energy, Deploys, and Spending. |
| `screenshot-tv-activities.png` | The Live Activities dashboard with the running Washing machine activity. |

Refresh only the Live Activities image with `ios/scripts/capture-tv-screenshots.sh --only activities`. Copy the full set with `ios/scripts/copy-screenshots.sh --set tvos --to /path/to/site/public/assets/tvos`.

## iPhone without Dynamic Island

Older iPhones use the same four in-app screenshots, captured with `--only app` and an explicit `--device`. They do not produce the compact or expanded Dynamic Island images, and the current flow deliberately avoids relying on their different Home Screen layout. If these display classes are published, place them in a separate output directory with `--out`; they are not a separate set understood by `copy-screenshots.sh`.

## iPad

iPad captures the same four in-app surfaces plus the classic and insights Home Screen layouts. Because iPad has no Dynamic Island, `screenshot-home-widgets.png` is the ordinary three-widget Home Screen rather than an expanded Live Activity, and no `screenshot-home-dynamic-island.png` is created. The standard App Store run uses `ios/scripts/capture-screenshots.sh --device "iPad Pro 13-inch (M4)"`, writes 2064×2752 files to `ios/build/screenshots/ipad/`, and can be copied with `ios/scripts/copy-screenshots.sh --set ipad --to /path/to/site/public/assets/ipad`.

## Implementation source

The capture behavior and attachment names live in `ios/UITests/ScreenshotTests.swift` and `ios/TVUITests/TVScreenshotTests.swift`. The entry points are `ios/scripts/capture-screenshots.sh`, `ios/scripts/capture-tv-screenshots.sh`, and `ios/scripts/copy-screenshots.sh`.
