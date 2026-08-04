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
#   ios/scripts/capture-screenshots.sh --device "iPhone 17 Pro" --out /tmp/shots
#
# Output is PNGs named after the XCTAttachment names in UITests/ScreenshotTests.swift.
set -euo pipefail

DEVICE="iPhone 17 Pro"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/screenshots"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

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

echo "→ running ScreenshotTests"
# CODE_SIGNING_ALLOWED=NO keeps this runnable without a Developer team. It also
# means no entitlements are embedded, so the App Group container is unavailable
# and CardCache.save is a no-op — the sample cards render from memory only,
# which is all the screenshots need.
xcodebuild test \
  -project ZeroZeroWidget.xcodeproj \
  -scheme ZeroZeroWidgetScreenshots \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -resultBundlePath "$RESULT" \
  CODE_SIGNING_ALLOWED=NO \
  ZW_DEBUG_TOOLS=YES \
  > "$WORK/xcodebuild.log" 2>&1 || {
    echo "✗ UI test failed — tail of log:" >&2
    tail -40 "$WORK/xcodebuild.log" >&2
    exit 1
  }

echo "→ exporting attachments"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$WORK/attachments" >/dev/null

mkdir -p "$OUT"
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
