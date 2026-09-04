# App Store Preview capture

`marketing/app-preview/run.sh` turns the prepared `00Widget Marketing` iPhone
Simulator into a deterministic 24-second App Store Preview. It builds the
private screenshot scheme, seeds offline fixtures, records the Simulator
framebuffer, runs a monotonic XCUITest timeline, renders prompt cards with
FFmpeg, and validates the MP4 with ffprobe.

## Requirements

- Xcode 26 or newer with the configured iOS Simulator runtime
- XcodeGen
- FFmpeg and ffprobe
- Python 3 with Pillow (`python3.12 -m pip install -r scripts/requirements.txt`)
- the one-time Simulator setup in [simulator.md](simulator.md)

The committed `.yaml` config is deliberately JSON-compatible YAML. This keeps
the timeline data-driven without adding PyYAML to the capture environment.

## Capture

From the repository root:

```sh
./marketing/app-preview/run.sh ios-main
```

The result is:

```text
artifacts/app-preview/
  raw.mov
  preview.mp4
  preview.json
```

The JSON report records the device/runtime, measured scene timestamps, overlay
copy and timing, config checksum, and every ffprobe validation result. Generated
movies are ignored by Git; `.gitkeep` preserves the output directory.

Useful options:

```sh
./marketing/app-preview/run.sh ios-main --device "iPhone 17 Pro"
./marketing/app-preview/run.sh ios-main --prepare-only
./marketing/app-preview/run.sh ios-main --app /path/to/ZeroZeroWidgetApp.app
./marketing/app-preview/run.sh ios-main --raw-only
./marketing/app-preview/run.sh ios-main --render-only
./marketing/app-preview/run.sh ios-main --config marketing/app-preview/another.yaml
./marketing/app-preview/run.sh ios-main --keep-temp --verbose
```

`--app` must be a Simulator build with the `ZW_SCREENSHOTS` fixture mode and
the same widget kinds as the prepared device. The UI-test bundle is still built
locally because it is the system interaction driver. Neither normal capture nor
supplied-app mode uninstalls the app, erases the device, or clears the shared
App Group.

`--render-only` reads the existing `raw.mov`, making copy, timing, style, size,
bitrate and duration changes cheap. The three overlay styles are `prompt`,
`headline`, and `caption`. Each prompt is first rendered as a transparent,
rounded PNG with the installed SF system font, then faded and composited by
FFmpeg. Font files are referenced in place and never copied.

## Timeline behavior

Scene actions run against one `systemUptime` baseline in XCUITest, rather than
sleeping relative to the previous scene. Supported actions are `hold`,
`go_home`, `swipe_left`, `swipe_right`, `open_app`, `tap` (by stable
accessibility identifier or label, never coordinates), and `preview_phase` (`a`/`b`/`c`,
a screenshot-only Live Activity `ContentState` update posted to the app over
the Darwin notification center so the island can change mid-timeline while the
recording stays on SpringBoard; the app holds a screenshot-only background
task so it is still alive to apply it).

`stage.initialPage` counts ordinary Home Screen pages from zero. The driver
first leaves iOS's far-left Today/widgets view, so `0` is the first page of apps
and widgets rather than the Today view.

The Simulator has no stable public command for lock/sleep control, and XCTest's
Simulator device button API exposes Home but not Lock. The config validator
therefore rejects `lock`, `wake`, and `sleep_wake` with an actionable message.
If a later preview needs the Lock Screen, add a small macOS UI-automation driver
as a separate adapter; do not put hard-coded screen coordinates into the
capture or rendering code.

The host/test handshake excludes Xcode startup from the movie:

1. XCUITest launches `--marketing-demo`, refreshes the widgets, and stages the
   configured initial Home Screen page.
2. It writes a run-specific `ready` marker and waits.
3. The host starts `simctl io recordVideo`, then writes `start`.
4. XCUITest runs the scene timeline and writes actual timestamps.
5. The host stops recording with `SIGINT` immediately after `finished`.

Both the recorder and UI test are terminated from cleanup handlers after an
error or signal. The status-bar override is also cleared.

## Validation

The final MP4 must be 15–30 seconds, exactly the configured dimensions, no more
than 30 fps, H.264 High Profile Level 4.0 or lower, progressive, and under 500
MB. It also includes the App Store-required stereo AAC-LC track at 48 kHz and a
target bitrate of 256 kbps; the track carries inaudible dither rather than
content. A failed check exits nonzero.
Run the validator directly when useful:

```sh
python3 marketing/app-preview/tools/validate.py ios-main artifacts/app-preview/preview.mp4
```
