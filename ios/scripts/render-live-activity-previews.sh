#!/usr/bin/env bash
# Render every canonical Lock Screen Live Activity at two real phone widths.
#
# Usage:
#   ios/scripts/render-live-activity-previews.sh
#   ios/scripts/render-live-activity-previews.sh --device "iPhone 17 Pro"
#   ios/scripts/render-live-activity-previews.sh --output /tmp/activity-previews
#   ios/scripts/render-live-activity-previews.sh --include-island
#   ios/scripts/render-live-activity-previews.sh --include-island --island-device "iPhone 18 Pro"
set -euo pipefail

DEVICE="${SIM_DEVICE:-iPhone 17 Pro}"
ISLAND_DEVICE="${SIM_ISLAND_DEVICE:-iPhone 18 Pro}"
OUTPUT=""
INCLUDE_ISLAND=0
ISLAND_DEVELOPER_DIR="${ZW_ISLAND_DEVELOPER_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --island-device) ISLAND_DEVICE="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --include-island) INCLUDE_ISLAND=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

IOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$IOS_ROOT/.." && pwd)"
OUTPUT="${OUTPUT:-$REPO_ROOT/artifacts/live-activity-previews}"
DERIVED="${ZW_LIVE_ACTIVITY_PREVIEW_DERIVED_DATA:-$IOS_ROOT/build/LiveActivityPreviewDerivedData-ios}"
LOG="$(mktemp -t zw-live-activity-previews).log"
trap 'rm -f "$LOG"' EXIT

if [[ ! -f "$IOS_ROOT/project.yml" ]]; then
  echo "ios/project.yml not found — copy it from ios/project.yml.sample first" >&2
  exit 1
fi

echo "→ generating Xcode project"
cd "$IOS_ROOT"
xcodegen >/dev/null

echo "→ booting simulator: $DEVICE"
xcrun simctl boot "$DEVICE" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

echo "→ rendering canonical Lock Screen fixtures"
if ! xcodebuild test \
  -quiet \
  -project ZeroZeroWidget.xcodeproj \
  -scheme ZeroZeroWidgetLiveActivityPreviews \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  >"$LOG" 2>&1; then
  echo "✗ preview render failed — tail of log:" >&2
  tail -80 "$LOG" >&2
  exit 1
fi

SOURCE="$(sed -n 's/.*ZW_PREVIEW_DIR=//p' "$LOG" | tail -1)"
if [[ -z "$SOURCE" || ! -d "$SOURCE" ]]; then
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/ZeroZeroWidgetApp.app"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
  CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
  SOURCE="$CONTAINER/tmp/live-activity-previews"
fi

if [[ ! -d "$SOURCE" || "$OUTPUT" == "/" || -z "$OUTPUT" ]]; then
  echo "✗ renderer did not produce a safe preview directory" >&2
  exit 1
fi

mkdir -p "$OUTPUT"
find "$OUTPUT" -maxdepth 1 -type f \( -name '*.png' -o -name 'manifest.json' \) -delete
cp -R "$SOURCE/." "$OUTPUT/"

COUNT="$(find "$OUTPUT" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
echo "✓ wrote $COUNT previews to $OUTPUT"

if ((INCLUDE_ISLAND)); then
  if [[ -z "$ISLAND_DEVELOPER_DIR" ]]; then
    for candidate in \
      "${DEVELOPER_DIR:-}" \
      "$(xcode-select -p 2>/dev/null || true)" \
      "/Applications/Xcode 27.app/Contents/Developer" \
      "/Applications/Xcode 27 RC.app/Contents/Developer"; do
      [[ -n "$candidate" && -d "$candidate" ]] || continue
      sdk_version="$(DEVELOPER_DIR="$candidate" xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || true)"
      if [[ "$sdk_version" == 27* ]]; then
        ISLAND_DEVELOPER_DIR="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$ISLAND_DEVELOPER_DIR" ]]; then
    echo "✗ --include-island needs Xcode 27; set ZW_ISLAND_DEVELOPER_DIR" >&2
    exit 1
  fi

  echo "→ capturing system-hosted Dynamic Islands on $ISLAND_DEVICE"
  DEVELOPER_DIR="$ISLAND_DEVELOPER_DIR" \
  ZW_SCREENSHOT_DERIVED_DATA="${ZW_ISLAND_DERIVED_DATA:-$IOS_ROOT/build/LiveActivityIslandDerivedData-ios27}" \
    "$REPO_ROOT/marketing/screenshots/capture-ios.sh" \
      --only island \
      --device "$ISLAND_DEVICE" \
      --out "$OUTPUT/system-island"
  echo "✓ four compact types in portrait + landscape, and expanded, are in $OUTPUT/system-island"
else
  echo "  Add --include-island for all compact types in portrait + landscape, and expanded."
fi
