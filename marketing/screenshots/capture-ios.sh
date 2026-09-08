#!/usr/bin/env bash
# Captures the marketing screenshots used on 00widget.com.
#
# Why a UI test rather than `simctl io screenshot`: the simulator offers no way
# to drive the app from outside. It opens on Settings until an API key is in the
# Keychain (which cannot be seeded from outside the device), `onOpenURL` forwards
# external links instead of routing tabs, and there is no tap tooling — `simctl`
# has no tap verb, and the Simulator exposes no accessibility windows. XCUITest
# runs on-device and can tap, so it drives the app into each state.
#
#   marketing/screenshots/capture-ios.sh
#   marketing/screenshots/capture-ios.sh --only activities
#   marketing/screenshots/capture-ios.sh --only app
#   marketing/screenshots/capture-ios.sh --only lock
#   marketing/screenshots/capture-ios.sh --only clip
#   marketing/screenshots/capture-ios.sh --only lock --no-consent-check
#   marketing/screenshots/capture-ios.sh --only island
#   marketing/screenshots/capture-ios.sh --only subscriptions
#   marketing/screenshots/capture-ios.sh --device "iPhone 17 Pro" --out /tmp/shots
#   marketing/screenshots/capture-ios.sh --device "iPad Pro 13-inch (M4)"
#
# The Lock Screen surface (`--only lock`, also part of the full run) is captured
# differently: XCUITest stages the launch Live Activity and pauses on a marker
# while the host-side sim-lock-capture.sh locks the simulator through its
# accessibility menu and screenshots the framebuffer with `simctl io`. An
# in-process screenshot could never show that surface.
#
# The App Clip surface (`--only clip`, also part of the full run) is host-side
# for a different reason: a clip is launched by an App Clip experience
# resolving an invocation URL, a capture simulator has no such experience
# registered, and `simctl openurl` on the link therefore opens Safari. The clip
# is built, installed and launched with `--guest-fixture`, which a
# ZW_SCREENSHOTS build reads as the one marketing guest token — the same token
# the app's QR encodes in the frame beside it.
#
# Output is PNGs named after the XCTAttachment names in UITests/ScreenshotTests.swift.
set -euo pipefail

DEVICE="iPhone 17 Pro"
OUT=""
ONLY="all"
CONSENT_CHECK_ARGS=()

run_with_heartbeat() {
  local label="$1"
  local log="$2"
  shift 2

  "$@" > "$log" 2>&1 &
  local command_pid=$!
  local started=$SECONDS
  local next_heartbeat=30
  local status=0
  while kill -0 "$command_pid" 2>/dev/null; do
    sleep 5
    local elapsed=$((SECONDS - started))
    if kill -0 "$command_pid" 2>/dev/null && ((elapsed >= next_heartbeat)); then
      echo "  … $label still running (${elapsed}s elapsed)"
      next_heartbeat=$((next_heartbeat + 30))
    fi
  done
  wait "$command_pid" || status=$?
  return "$status"
}

# Drives the Lock Screen surface: the marker UI test stages the launch Live
# Activity and pauses on $WORK/lock-handshake/ready while sim-lock-capture.sh
# locks the simulator through accessibility and screenshots the framebuffer.
# The adapter answers $WORK/lock-handshake/done, which unblocks the test.
run_lock_surface() {
  local handshake="$WORK/lock-handshake"
  mkdir -p "$OUT" "$handshake"
  /usr/libexec/PlistBuddy \
    -c "Delete :ZeroZeroWidgetUITests:EnvironmentVariables:ZW_LOCK_HANDSHAKE_DIR" \
    "$XCTESTRUN" 2>/dev/null || true
  /usr/libexec/PlistBuddy \
    -c "Add :ZeroZeroWidgetUITests:EnvironmentVariables:ZW_LOCK_HANDSHAKE_DIR string $handshake" \
    "$XCTESTRUN"

  echo "→ staging the Live Activity for the Lock Screen capture"
  xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -resultBundlePath "$WORK/lock.xcresult" \
    -only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureLockScreenStaging \
    > "$WORK/lock-xcodebuild.log" 2>&1 &
  local test_pid=$!

  local adapter_status=0
  local app_bundle
  app_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
  "$SCRIPT_DIR/sim-lock-capture.sh" \
    --device "$DEVICE" \
    --bundle-id "$app_bundle" \
    --handshake-dir "$handshake" \
    "${CONSENT_CHECK_ARGS[@]}" \
    --out "$OUT/$LOCK_PNG" || adapter_status=$?

  local test_status=0
  wait "$test_pid" || test_status=$?

  if ((adapter_status != 0)); then
    echo "✗ lock-screen adapter failed — tail of the staging log:" >&2
    tail -40 "$WORK/lock-xcodebuild.log" >&2
    kill "$test_pid" 2>/dev/null || true
    return 1
  fi
  if ((test_status != 0)); then
    echo "✗ lock staging test failed — tail of log:" >&2
    tail -40 "$WORK/lock-xcodebuild.log" >&2
    return 1
  fi

  python3 - "$OUT" "$DEVICE" <<'PY'
import datetime, hashlib, json, os, sys

dest, device = sys.argv[1:]
name = "screenshot-lock-activity.png"
path = os.path.join(dest, name)
with open(path, "rb") as handle:
    digest = hashlib.md5(handle.read()).hexdigest()
manifest_path = os.path.join(dest, ".capture-manifest.json")
try:
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("device") != device:
        raise ValueError("existing manifest is for a different device")
except (OSError, ValueError):
    manifest = {
        "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "device": device,
        "mode": "lock",
        "files": {},
    }
manifest.setdefault("files", {})[name] = digest
with open(manifest_path, "w") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(f"  {name} {digest}")
PY
}

# Drives the App Clip surface: the other half of the share frame.
#
# There is no XCUITest way in. A clip is launched by an App Clip experience
# resolving an invocation URL, no such experience is registered on a capture
# simulator, and `simctl openurl` on the link therefore opens Safari. So the
# clip is built, installed and launched directly with `--guest-fixture`, which
# a ZW_SCREENSHOTS build reads as "open the one marketing token" — the same
# token the app's QR encodes in the frame beside it.
#
# It runs after every XCUITest capture and uninstalls itself afterwards: an
# installed clip is an extra icon on the Home Screen, and the Home Screen is
# three of this run's images.
run_clip_surface() {
  local udid
  udid="$(xcrun simctl list devices -j | python3 -c "
import json, sys
name = sys.argv[1]
for runtime in json.load(sys.stdin)['devices'].values():
    for device in runtime:
        if device['name'] == name and device.get('isAvailable'):
            print(device['udid'])
            raise SystemExit(0)
raise SystemExit('no available simulator named ' + name)
" "$DEVICE")" || return 1

  echo "→ building the App Clip"
  if ! run_with_heartbeat "App Clip build" "$WORK/clip-build.log" xcodebuild build \
    -project ZeroZeroWidget.xcodeproj \
    -scheme ZeroZeroWidgetClip \
    -destination "platform=iOS Simulator,name=$DEVICE" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="ZW_SHARING_ENABLED ZW_SCREENSHOTS ZW_SUBSCRIPTIONS_ENABLED"; then
    echo "✗ App Clip build failed — tail of log:" >&2
    tail -40 "$WORK/clip-build.log" >&2
    return 1
  fi

  local clip="$DERIVED/Build/Products/Debug-iphonesimulator/ZeroZeroWidgetClip.app"
  local clip_id
  clip_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$clip/Info.plist")"

  echo "→ launching the App Clip on the fixture link"
  xcrun simctl install "$udid" "$clip"
  xcrun simctl launch "$udid" "$clip_id" --guest-fixture >/dev/null

  # The clip renders the card through the production CardView the moment the
  # fixture resolves; the wait is for the launch animation, not for a network.
  sleep 6
  xcrun simctl io "$udid" screenshot --type=png "$OUT/$CLIP_PNG" >/dev/null 2>&1

  xcrun simctl terminate "$udid" "$clip_id" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$clip_id" >/dev/null 2>&1 || true

  python3 - "$OUT" "$DEVICE" "$CLIP_PNG" <<'CLIPMANIFEST'
import datetime, hashlib, json, os, sys

dest, device, name = sys.argv[1:]
path = os.path.join(dest, name)
with open(path, "rb") as handle:
    digest = hashlib.md5(handle.read()).hexdigest()
manifest_path = os.path.join(dest, ".capture-manifest.json")
try:
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("device") != device:
        raise ValueError("existing manifest is for a different device")
except (OSError, ValueError):
    manifest = {
        "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "device": device,
        "mode": "clip",
        "files": {},
    }
manifest.setdefault("files", {})[name] = digest
with open(manifest_path, "w") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(f"  {name} {digest}")
CLIPMANIFEST
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    # Skips the Lock Screen consent detection. Use it only after looking at a
    # capture from this device and confirming there is no prompt in it: the
    # detector fires on an activity item row (see lock_consent.py), so a device
    # that answered its prompt long ago can fail a run it should pass.
    --no-consent-check) CONSENT_CHECK_ARGS=(--no-consent-check); shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$ONLY" != "all" && "$ONLY" != "activities" && "$ONLY" != "app" && "$ONLY" != "lock" && "$ONLY" != "clip" && "$ONLY" != "island" && "$ONLY" != "subscriptions" ]]; then
  echo "--only must be 'all', 'activities', 'app', 'lock', 'clip', 'island', or 'subscriptions'" >&2
  exit 2
fi

# Hold the display awake for the whole run.
#
# Not a convenience: a locked Mac hides every window from the accessibility
# tree, and the Lock Screen capture drives Simulator.app through it. A run
# started before lunch reached the lock step with Simulator running, the device
# booted, and zero windows visible to `System Events` — ten minutes of capture
# thrown away for a screen saver. `-w $$` ties the assertion to this script, so
# it lifts when the run ends however it ends, with no trap to forget.
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -dimsu -w $$ &
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_PNG="screenshot-lock-activity.png"
CLIP_PNG="screenshot-clip.png"
IOS_ROOT="$REPO_ROOT/ios"
case "$DEVICE" in
  "iPhone 17 Pro") DEVICE_FOLDER="iphone-6.3" ;;
  "iPhone 14 Plus – App Store 6.5") DEVICE_FOLDER="iphone-6.5" ;;
  iPad*) DEVICE_FOLDER="ipad" ;;
  *)
    DEVICE_FOLDER="$(printf '%s' "$DEVICE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')"
    ;;
esac
if [[ -z "$OUT" ]]; then
  OUT="$REPO_ROOT/artifacts/screenshots/raw/$DEVICE_FOLDER"
  if [[ "$ONLY" == "subscriptions" ]]; then
    OUT="$OUT/subscriptions"
  fi
  # The Island probe is a diagnostic, never an App Store asset, so it stays
  # out of the canonical raw tree that the manifests and the compositor read.
  if [[ "$ONLY" == "island" ]]; then
    OUT="$REPO_ROOT/artifacts/screenshots/probe/$DEVICE_FOLDER"
  fi
fi

cd "$IOS_ROOT"

if [[ ! -d ZeroZeroWidget.xcodeproj ]]; then
  echo "→ generating project"
  xcodegen
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RESULT="$WORK/screenshots.xcresult"

# Start from a fresh boot. Something in a device's accumulated state makes the
# compact Dynamic Island draw its content clipped inside a full-width pill —
# not reliably, but often enough that the hero failed its check three runs in a
# row, and a reboot has produced a clean one each time it has been tried. The
# cause is unknown; SpringBoard restarting with the device is the cheapest
# thing that clears it, and it costs half a minute against a ten-minute run.
#
# Erasing would clear it too, and must not be used: it also removes the Lock
# Screen accessory widgets, which are placed by hand and cannot yet be
# automated.
echo "→ restarting $DEVICE"
xcrun simctl shutdown "$DEVICE" 2>/dev/null || true
sleep 3
echo "→ booting $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

# A headless `simctl boot` is not enough for reliable SpringBoard accessibility.
# Keep Simulator.app open so XCUITest has a visible host for Home Screen and
# Dynamic Island interactions.
echo "→ opening Simulator.app"
open -a Simulator
for _ in {1..20}; do
  if pgrep -x Simulator >/dev/null; then
    break
  fi
  sleep 0.25
done
if ! pgrep -x Simulator >/dev/null; then
  echo "✗ Simulator.app did not launch" >&2
  exit 1
fi

# The Lock Screen step drives Simulator.app through the accessibility tree,
# which needs macOS Accessibility permission for this terminal. Fail fast here
# — before the build — so a missing grant does not waste a full capture run.
if [[ "$ONLY" == "all" || "$ONLY" == "lock" ]]; then
  echo "→ lock-capture preflight (Simulator accessibility)"
  if ! "$SCRIPT_DIR/sim-lock-capture.sh" --preflight-only --device "$DEVICE"; then
    exit 3
  fi
fi

# Marketing shots should not leak a real clock or a half-empty battery.
echo "→ pinning status bar to 9:41"
xcrun simctl status_bar "$DEVICE" override \
  --time "9:41" --cellularBars 4 --wifiBars 3 \
  --batteryState charged --batteryLevel 100 2>/dev/null || true

# Build, re-sign, then run — rather than a plain `xcodebuild test`.
#
# `CODE_SIGNING_ALLOWED=NO` embeds no entitlements, which leaves the App Group
# container unavailable. The app survives that (cards fall back to memory) but
# the *widget extension* is a separate process and cannot, so every widget
# renders empty. Re-signing between build and run, the way build-sim.sh does,
# gives both processes the container: widgets read real cards, and the
# "hide sample indicators" flag reaches the extension.
# Keep DerivedData between runs. Xcode still invalidates changed inputs, while
# iterative screenshot work avoids recompiling the entire app and test bundle.
# The cache lives under gitignored ios/build and can be overridden or deleted
# whenever a genuinely clean build is wanted.
DERIVED="${ZW_SCREENSHOT_DERIVED_DATA:-$IOS_ROOT/build/ScreenshotDerivedData-ios}"

echo "→ building for testing"
if ! run_with_heartbeat "iOS screenshot build" "$WORK/build.log" xcodebuild build-for-testing \
  -project ZeroZeroWidget.xcodeproj \
  -scheme ZeroZeroWidgetScreenshots \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="ZW_SHARING_ENABLED ZW_SCREENSHOTS ZW_SUBSCRIPTIONS_ENABLED"; then
  echo "✗ build failed — tail of log:" >&2
  tail -40 "$WORK/build.log" >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Debug-iphonesimulator/ZeroZeroWidgetApp.app"
EXT="$APP/PlugIns/ZeroZeroWidgetWidgets.appex"
APP_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :ZWAppGroupIdentifier' "$APP/Info.plist")"

# `test-without-building` does not inherit the Run action's StoreKit
# configuration. The screenshot-only app decodes its plan previews from this
# injected catalog instead. Re-signing below seals the added resource into the
# bundle.
cp "$IOS_ROOT/Resources/ZeroZeroWidget.storekit" "$APP/ZeroZeroWidget.storekit"

echo "→ re-signing with App Group entitlements"
ENTITLEMENTS="$WORK/sim.entitlements"
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array><string>${APP_GROUP}</string></array>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$EXT" >/dev/null 2>&1
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP" >/dev/null 2>&1

XCTESTRUN="$(ls "$DERIVED/Build/Products/"*.xctestrun | head -1)"
/usr/libexec/PlistBuddy \
  -c "Delete :ZeroZeroWidgetUITests:EnvironmentVariables:ZW_SCREENSHOT_DEVICE_CLASS" \
  "$XCTESTRUN" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Add :ZeroZeroWidgetUITests:EnvironmentVariables:ZW_SCREENSHOT_DEVICE_CLASS string $DEVICE_FOLDER" \
  "$XCTESTRUN"

if [[ "$ONLY" != "lock" && "$ONLY" != "clip" ]]; then
  echo "→ running ScreenshotTests"
fi
if [[ "$ONLY" == "activities" ]]; then
  TEST_FILTERS=(
    -only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureActivitiesScreenshot
  )
elif [[ "$ONLY" == "app" ]]; then
  TEST_FILTERS=(
    -only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureAppScreenshots
  )
elif [[ "$ONLY" == "lock" ]]; then
  TEST_FILTERS=()
elif [[ "$ONLY" == "island" ]]; then
  TEST_FILTERS=(
    -only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureIslandProbe
  )
elif [[ "$ONLY" == "subscriptions" ]]; then
  TEST_FILTERS=(
    -only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureSubscriptionScreenshots
    -only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureSubscriptionNotice
  )
else
  TEST_FILTERS=(
    -only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureMarketingScreenshots
  )
fi
# The two host-side surfaces drive nothing in the app, so neither runs a
# test — but both still need the build above, for the app the clip installs
# beside and for the xctestrun the lock handshake edits.
if [[ "$ONLY" != "lock" && "$ONLY" != "clip" ]]; then
if ! run_with_heartbeat "iOS ScreenshotTests on $DEVICE" "$WORK/xcodebuild.log" xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -resultBundlePath "$RESULT" \
  "${TEST_FILTERS[@]}"; then
  echo "✗ UI test failed — tail of log:" >&2
  tail -40 "$WORK/xcodebuild.log" >&2
  exit 1
fi

echo "→ exporting attachments"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$WORK/attachments" >/dev/null

mkdir -p "$OUT"
python3 - "$WORK/attachments" "$OUT" "$ONLY" "$DEVICE" "$DEVICE_FOLDER" <<'PY'
import datetime, hashlib, json, os, re, shutil, sys

src, dest, mode, device, device_class = sys.argv[1:]
manifest = json.load(open(os.path.join(src, "manifest.json")))

def entries(node):
    if isinstance(node, dict):
        if "exportedFileName" in node and "suggestedHumanReadableName" in node:
            yield node
        for value in node.values():
            yield from entries(value)
    elif isinstance(node, list):
        for value in node:
            yield from entries(value)

count = 0
produced = set()
for entry in entries(manifest):
    # XCTest appends _<index>_<UUID> to the attachment name.
    name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(\.\w+)$", r"\1", entry["suggestedHumanReadableName"])
    shutil.copy2(os.path.join(src, entry["exportedFileName"]), os.path.join(dest, name))
    print(f"  {name}")
    produced.add(name)
    count += 1
if count == 0:
    raise SystemExit("no screenshot attachments found in result bundle")

required = set()
if mode == "activities":
    required = {"screenshot-activities.png"}
elif mode == "island":
    required = {"probe-island-compact.png", "probe-island-expanded.png"}
elif mode == "app":
    required = {
        "screenshot-approve.png",
        "screenshot-share.png",
        "screenshot-insights.png",
        "screenshot-activities.png",
    }
elif mode == "all":
    required = {
        "screenshot-approve.png",
        "screenshot-share.png",
        "screenshot-home-widgets.png",
        "screenshot-home-insights.png",
        "screenshot-home-metrics.png",
        "screenshot-insights.png",
        "screenshot-activities.png",
    }
    # Only one capture device has a Dynamic Island, so only one set carries
    # the expanded presentation. It is a source rather than a promotional
    # image: the compositor insets it into the Lock Screen frame, which is
    # where the sequence now makes its system-surface claim.
    if device_class == "iphone-6.3":
        required.add("screenshot-island-expanded.png")
        # Website-only payoff: the same launch after approval, at 5/5. It is
        # intentionally absent from the other device sets and the App Store
        # promotional sequence.
        required.add("screenshot-launch-complete.png")

missing = sorted(required - produced)
if missing:
    raise SystemExit(
        "capture did not produce required fresh attachments: " + ", ".join(missing)
    )

if mode == "all":
    # The Lock Screen and App Clip are captured host-side after this runs, so
    # they are not in `produced` and must not be swept as strays.
    host_side = {"screenshot-lock-activity.png", "screenshot-clip.png"}
    for name in os.listdir(dest):
        if (
            name.startswith("screenshot-")
            and name.endswith(".png")
            and name not in required
            and name not in host_side
        ):
            os.unlink(os.path.join(dest, name))

    files = {}
    for name in sorted(produced):
        path = os.path.join(dest, name)
        if os.path.isfile(path) and name.endswith(".png"):
            with open(path, "rb") as handle:
                files[name] = hashlib.md5(handle.read()).hexdigest()
    provenance = {
        "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "device": device,
        "mode": mode,
        "files": files,
    }
    with open(os.path.join(dest, ".capture-manifest.json"), "w") as handle:
        json.dump(provenance, handle, indent=2, sort_keys=True)
        handle.write("\n")
else:
    # A partial run refreshes real files, so it owes the manifest their new
    # checksums — otherwise the set verifies as stale against captures that are
    # in fact newer than the ones recorded, and the only way back to green is a
    # fifteen-minute full run that recaptures nine correct images to fix the
    # bookkeeping on one. This merges, exactly as the Lock Screen and App Clip
    # steps already do: `mode` and `device` stay whatever the full run wrote,
    # because they describe how the *set* was produced and a targeted refresh
    # does not change that.
    manifest_path = os.path.join(dest, ".capture-manifest.json")
    try:
        with open(manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        if manifest.get("device") != device:
            raise ValueError("existing manifest is for a different device")
    except (OSError, ValueError, json.JSONDecodeError):
        manifest = {
            "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "device": device,
            "mode": mode,
            "files": {},
        }
    files = manifest.setdefault("files", {})
    for name in sorted(produced):
        path = os.path.join(dest, name)
        if os.path.isfile(path) and name.endswith(".png"):
            with open(path, "rb") as handle:
                files[name] = hashlib.md5(handle.read()).hexdigest()
    with open(manifest_path, "w") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
PY
fi

# A hero whose Island content is cut off is not an App Store screenshot, and
# nothing else in the pipeline can see the difference — the manifest checks
# names, checksums and sizes, and a clipped glyph is none of those. It varies
# between runs of identical code, so the answer is to catch it and re-run.
if [[ "$ONLY" == "all" && "$DEVICE_FOLDER" == "iphone-6.3" ]]; then
  echo "→ checking the Dynamic Island is not clipped"
  for island_capture in screenshot-home-widgets.png screenshot-launch-complete.png; do
    if ! python3 "$SCRIPT_DIR/island_check.py" "$OUT/$island_capture"; then
      echo "✗ re-run: $island_capture has clipped Dynamic Island content" >&2
      exit 1
    fi
  done
fi

if [[ "$ONLY" == "all" || "$ONLY" == "clip" ]]; then
  echo "→ capturing the App Clip surface"
  run_clip_surface || exit 1
fi

if [[ "$ONLY" == "all" || "$ONLY" == "lock" ]]; then
  echo "→ capturing the Lock Screen surface"
  run_lock_surface
  if [[ "$ONLY" == "lock" ]]; then
    echo "  note: --only lock refreshes $LOCK_PNG in place and updates its manifest entry"
  fi
fi

if [[ "$ONLY" == "island" ]]; then
  python3 - "$OUT" <<'CROP'
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # the crop is a convenience, not the capture
    raise SystemExit(0)

out = Path(sys.argv[1])
for name, depth in (("probe-island-compact", 0.09), ("probe-island-expanded", 0.22)):
    source = out / f"{name}.png"
    if not source.is_file():
        continue
    with Image.open(source) as image:
        crop = image.crop((0, 0, image.width, round(image.height * depth)))
        crop = crop.resize((crop.width * 2, crop.height * 2), Image.Resampling.LANCZOS)
        crop.save(out / f"{name}-zoom.png")
    print(f"  {name}-zoom.png")
CROP
fi

echo "→ restoring status bar"
xcrun simctl status_bar "$DEVICE" clear 2>/dev/null || true

echo "✓ screenshots in $OUT"
