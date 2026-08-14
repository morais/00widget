#!/usr/bin/env bash
# Captures native 1920x1080 Apple TV marketing screenshots via XCUITest.
#
#   ios/scripts/capture-tv-screenshots.sh
#   ios/scripts/capture-tv-screenshots.sh --only activities
#   ios/scripts/capture-tv-screenshots.sh --device "Apple TV 4K (3rd generation) (at 1080p)"
#   ios/scripts/capture-tv-screenshots.sh --out /tmp/tv-shots
set -euo pipefail

DEVICE="Apple TV 4K (3rd generation) (at 1080p)"
OUT=""
ONLY="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$ONLY" != "all" && "$ONLY" != "activities" ]]; then
  echo "--only must be 'all' or 'activities'" >&2
  exit 2
fi

IOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$IOS_ROOT/build/screenshots/tvos}"
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

echo "→ running TVScreenshotTests"
if [[ "$ONLY" == "activities" ]]; then
  TEST_FILTERS=(
    -only-testing:ZeroZeroWidgetTVUITests/TVScreenshotTests/testCaptureActivitiesScreenshot
  )
else
  TEST_FILTERS=(
    -only-testing:ZeroZeroWidgetTVUITests/TVScreenshotTests/testCaptureActivitiesScreenshot
    -only-testing:ZeroZeroWidgetTVUITests/TVScreenshotTests/testCaptureWidgetsScreenshot
  )
fi

xcodebuild test \
  -project ZeroZeroWidget.xcodeproj \
  -scheme ZeroZeroWidgetTVScreenshots \
  -destination "platform=tvOS Simulator,name=$DEVICE" \
  -derivedDataPath "$WORK/DerivedData" \
  -resultBundlePath "$RESULT" \
  "${TEST_FILTERS[@]}" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="ZW_SHARING_ENABLED ZW_SCREENSHOTS" \
  > "$WORK/xcodebuild.log" 2>&1 || {
    echo "✗ TV UI test failed — tail of log:" >&2
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
    name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(\.\w+)$", r"\1", entry["suggestedHumanReadableName"])
    shutil.copy2(os.path.join(src, entry["exportedFileName"]), os.path.join(dest, name))
    print(f"  {name}")
    count += 1
if count == 0:
    raise SystemExit("no screenshot attachments found in result bundle")
PY

echo "✓ Apple TV screenshots in $OUT"
