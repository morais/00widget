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
#   ios/scripts/capture-screenshots.sh
#   ios/scripts/capture-screenshots.sh --only activities
#   ios/scripts/capture-screenshots.sh --only app
#   ios/scripts/capture-screenshots.sh --device "iPhone 17 Pro" --out /tmp/shots
#   ios/scripts/capture-screenshots.sh --device "iPad Pro 13-inch (M4)"
#
# Output is PNGs named after the XCTAttachment names in UITests/ScreenshotTests.swift.
set -euo pipefail

DEVICE="iPhone 17 Pro"
OUT=""
ONLY="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$ONLY" != "all" && "$ONLY" != "activities" && "$ONLY" != "app" ]]; then
  echo "--only must be 'all', 'activities', or 'app'" >&2
  exit 2
fi

IOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "$OUT" ]]; then
  if [[ "$DEVICE" == iPad* ]]; then
    OUT="$IOS_ROOT/build/screenshots/ipad"
  else
    OUT="$IOS_ROOT/build/screenshots"
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
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true

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
xcodebuild build-for-testing \
  -project ZeroZeroWidget.xcodeproj \
  -scheme ZeroZeroWidgetScreenshots \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="ZW_SHARING_ENABLED ZW_SCREENSHOTS" \
  ZW_DEBUG_TOOLS=YES \
  > "$WORK/build.log" 2>&1 || {
    echo "✗ build failed — tail of log:" >&2
    tail -40 "$WORK/build.log" >&2
    exit 1
  }

APP="$DERIVED/Build/Products/Debug-iphonesimulator/ZeroZeroWidgetApp.app"
EXT="$APP/PlugIns/ZeroZeroWidgetWidgets.appex"
APP_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :ZWAppGroupIdentifier' "$APP/Info.plist")"

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

echo "→ running ScreenshotTests"
if [[ "$ONLY" == "activities" ]]; then
  TEST_FILTER="-only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureActivitiesScreenshot"
elif [[ "$ONLY" == "app" ]]; then
  TEST_FILTER="-only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureAppScreenshots"
else
  TEST_FILTER="-only-testing:ZeroZeroWidgetUITests/ScreenshotTests/testCaptureMarketingScreenshots"
fi
xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -resultBundlePath "$RESULT" \
  "$TEST_FILTER" \
  > "$WORK/xcodebuild.log" 2>&1 || {
    echo "✗ UI test failed — tail of log:" >&2
    tail -40 "$WORK/xcodebuild.log" >&2
    exit 1
  }

echo "→ exporting attachments"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$WORK/attachments" >/dev/null

mkdir -p "$OUT"
# `screenshot-home-expanded.png` was an identical legacy alias for the
# canonical expanded `screenshot-home-widgets.png`. Clear it so old captures
# cannot make the output look as though two distinct screenshots still exist.
rm -f "$OUT/screenshot-home-expanded.png"
python3 - "$WORK/attachments" "$OUT" <<'PY'
import json, os, re, shutil, sys

src, dest = sys.argv[1], sys.argv[2]
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
for entry in entries(manifest):
    # XCTest appends _<index>_<UUID> to the attachment name.
    name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(\.\w+)$", r"\1", entry["suggestedHumanReadableName"])
    shutil.copy2(os.path.join(src, entry["exportedFileName"]), os.path.join(dest, name))
    print(f"  {name}")
    count += 1
if count == 0:
    raise SystemExit("no screenshot attachments found in result bundle")
PY

echo "→ restoring status bar"
xcrun simctl status_bar "$DEVICE" clear 2>/dev/null || true

echo "✓ screenshots in $OUT"
