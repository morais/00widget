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
# Output is PNGs named after the XCTAttachment names in UITests/ScreenshotTests.swift.
set -euo pipefail

DEVICE="iPhone 17 Pro"
OUT=""
ONLY="all"

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$ONLY" != "all" && "$ONLY" != "activities" && "$ONLY" != "app" && "$ONLY" != "lock" && "$ONLY" != "subscriptions" ]]; then
  echo "--only must be 'all', 'activities', 'app', 'lock', or 'subscriptions'" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_PNG="screenshot-lock-activity.png"
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
fi

cd "$IOS_ROOT"

if [[ ! -d ZeroZeroWidget.xcodeproj ]]; then
  echo "→ generating project"
  xcodegen
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RESULT="$WORK/screenshots.xcresult"

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

echo "→ running ScreenshotTests"
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
if [[ "$ONLY" != "lock" ]]; then
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
elif mode == "app":
    required = {
        "screenshot-widgets.png",
        "screenshot-insights.png",
        "screenshot-activities.png",
    }
elif mode == "all":
    required = {
        "screenshot-widgets.png",
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

missing = sorted(required - produced)
if missing:
    raise SystemExit(
        "capture did not produce required fresh attachments: " + ", ".join(missing)
    )

if mode == "all":
    for name in os.listdir(dest):
        if name.startswith("screenshot-") and name.endswith(".png") and name not in required:
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
PY
fi

if [[ "$ONLY" == "all" || "$ONLY" == "lock" ]]; then
  echo "→ capturing the Lock Screen surface"
  run_lock_surface
  if [[ "$ONLY" == "lock" ]]; then
    echo "  note: --only lock refreshes $LOCK_PNG in place; run the full capture to re-baseline the manifest"
  fi
fi

echo "→ restoring status bar"
xcrun simctl status_bar "$DEVICE" clear 2>/dev/null || true

echo "✓ screenshots in $OUT"
