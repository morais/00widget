#!/usr/bin/env bash
# Runs the app's XCTest accessibility audits at Large and AX5 on a disposable
# simulator. No existing simulator state, Keychain, or content-size preference
# is touched.
set -euo pipefail

DEVICE_TYPE="iPhone 17 Pro"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_TYPE="$2"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

IOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_WORK="$(mktemp -d)"
AUDIT_DEVICE_NAME="00Widget Accessibility Audit $$"
AUDIT_DEVICE_ID=""

cleanup() {
  if [[ -n "$AUDIT_DEVICE_ID" ]]; then
    xcrun simctl shutdown "$AUDIT_DEVICE_ID" >/dev/null 2>&1 || true
    xcrun simctl delete "$AUDIT_DEVICE_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$AUDIT_WORK"
}
trap cleanup EXIT

cd "$IOS_ROOT"
echo "→ generating Xcode project"
xcodegen >/dev/null

echo "→ creating disposable simulator: $DEVICE_TYPE"
AUDIT_DEVICE_ID="$(xcrun simctl create "$AUDIT_DEVICE_NAME" "$DEVICE_TYPE")"
xcrun simctl boot "$AUDIT_DEVICE_ID"
xcrun simctl bootstatus "$AUDIT_DEVICE_ID" -b >/dev/null

DERIVED="${ZW_ACCESSIBILITY_DERIVED_DATA:-$IOS_ROOT/build/AccessibilityDerivedData-ios}"
echo "→ building accessibility tests"
xcodebuild build-for-testing \
  -quiet \
  -project ZeroZeroWidget.xcodeproj \
  -scheme ZeroZeroWidgetAccessibility \
  -destination "platform=iOS Simulator,id=$AUDIT_DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="ZW_SHARING_ENABLED ZW_SCREENSHOTS ZW_SUBSCRIPTIONS_ENABLED ZW_ACCESSIBILITY_AUDITS" \
  > "$AUDIT_WORK/build.log" 2>&1 || {
    echo "✗ build failed — tail of log:" >&2
    tail -60 "$AUDIT_WORK/build.log" >&2
    exit 1
  }

APP="$DERIVED/Build/Products/Debug-iphonesimulator/ZeroZeroWidgetApp.app"
EXT="$APP/PlugIns/ZeroZeroWidgetWidgets.appex"
APP_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :ZWAppGroupIdentifier' "$APP/Info.plist")"
ENTITLEMENTS="$AUDIT_WORK/sim.entitlements"
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

echo "→ re-signing with simulator App Group entitlements"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$EXT" >/dev/null 2>&1
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP" >/dev/null 2>&1

XCTESTRUN="$(ls "$DERIVED/Build/Products/"*.xctestrun | head -1)"
for AUDIT_SIZE in large accessibility-extra-extra-extra-large; do
  if [[ "$AUDIT_SIZE" == "large" ]]; then
    AUDIT_LABEL="Large"
  else
    AUDIT_LABEL="AX5"
  fi
  echo "→ auditing at $AUDIT_LABEL"
  xcrun simctl ui "$AUDIT_DEVICE_ID" content_size "$AUDIT_SIZE"
  /usr/libexec/PlistBuddy \
    -c "Delete :ZeroZeroWidgetAccessibilityUITests:EnvironmentVariables:ZW_ACCESSIBILITY_AUDIT_SIZE" \
    "$XCTESTRUN" 2>/dev/null || true
  /usr/libexec/PlistBuddy \
    -c "Add :ZeroZeroWidgetAccessibilityUITests:EnvironmentVariables:ZW_ACCESSIBILITY_AUDIT_SIZE string $AUDIT_LABEL" \
    "$XCTESTRUN"
  xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "platform=iOS Simulator,id=$AUDIT_DEVICE_ID" \
    -resultBundlePath "$AUDIT_WORK/$AUDIT_LABEL.xcresult" \
    -only-testing:ZeroZeroWidgetAccessibilityUITests/AccessibilityAuditTests/testRepresentativeSurfaces \
    > "$AUDIT_WORK/$AUDIT_LABEL.log" 2>&1 || {
      echo "✗ $AUDIT_LABEL audit failed — tail of log:" >&2
      tail -80 "$AUDIT_WORK/$AUDIT_LABEL.log" >&2
      exit 1
    }
done

echo "✓ accessibility audits passed at Large and AX5"
