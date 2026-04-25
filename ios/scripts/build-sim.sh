#!/usr/bin/env bash
# Build, sign, install, and optionally launch ZeroWidgetApp on the iOS Simulator
# without requiring an Apple Developer team.
#
# Why this script exists (lessons from the first sim run):
#
# 1. `xcodebuild ... CODE_SIGNING_ALLOWED=NO` skips entitlements embedding
#    entirely. The app launches but `containerURL(forSecurityApplicationGroupIdentifier:)`
#    returns nil, so CardCache.save throws "App Group container unavailable" and
#    nothing the app fetches survives a relaunch (and the widget can't see it).
#
# 2. `xcodebuild ... CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO` builds, but
#    Xcode still doesn't run the entitlements-embedding step the way a full sign
#    pass would. The .app bundle has [Dict] entitlements, no keys.
#
# 3. Re-signing with the *production* .entitlements file (which claims
#    aps-environment) is rejected at launch by SBMainWorkspace:
#       "request was denied by service delegate (SBMainWorkspace)"
#    because the simulator can't satisfy the push entitlement without a real
#    provisioning profile.
#
# The fix: build with ad-hoc signing, then re-sign with App Group entitlement
# *only* — drop aps-environment for sim runs. Push doesn't work on sim anyway
# without explicit Simulator Push setup, so nothing is lost.
#
# Usage:
#   ios/scripts/build-sim.sh                                  # build + install
#   ios/scripts/build-sim.sh --launch                         # also launch
#   ios/scripts/build-sim.sh --device "iPhone 17 Pro"         # pick a sim
#   ios/scripts/build-sim.sh --base-url https://...           # seed UserDefaults

set -euo pipefail

DEVICE="${SIM_DEVICE:-iPhone 17 Pro}"
LAUNCH=0
BASE_URL="${ZW_BASE_URL:-}"
APP_GROUP="group.com.example.zerowidget"
BUNDLE_ID="com.example.zerowidget"

while [[ $# -gt 0 ]]; do
  case $1 in
    --launch) LAUNCH=1; shift ;;
    --device) DEVICE="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

cd "$(dirname "$0")/.."

if [[ ! -f project.yml ]]; then
  echo "ios/project.yml not found — copy from the committed template:"
  echo "  cp ios/project.yml.sample ios/project.yml"
  echo "Then edit it (DEVELOPMENT_TEAM, bundle ids, App Group) per ios/README.md."
  exit 1
fi

echo "→ regenerating Xcode project"
xcodegen >/dev/null

echo "→ booting simulator: $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator

echo "→ building"
xcodebuild \
  -project ZeroWidget.xcodeproj \
  -scheme ZeroWidgetApp \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  build >/dev/null

APP="build/Build/Products/Debug-iphonesimulator/ZeroWidgetApp.app"
WIDGETEXT="$APP/PlugIns/ZeroWidgetWidgets.appex"

echo "→ re-signing with sim-only entitlements (App Groups, no aps-environment)"
SIM_ENT="$(mktemp -t zw-sim-ent).plist"
cat > "$SIM_ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>${APP_GROUP}</string>
    </array>
</dict>
</plist>
EOF
codesign --force --sign - --entitlements "$SIM_ENT" "$WIDGETEXT"
codesign --force --sign - --entitlements "$SIM_ENT" "$APP"
rm "$SIM_ENT"

echo "→ installing"
xcrun simctl uninstall booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install booted "$APP"

if [[ -n "$BASE_URL" ]]; then
  PLIST="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data)/Library/Preferences/${BUNDLE_ID}.plist"
  mkdir -p "$(dirname "$PLIST")"
  /usr/libexec/PlistBuddy -c "Add :zw.serverBaseURL string $BASE_URL" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :zw.serverBaseURL $BASE_URL" "$PLIST"
  echo "→ seeded server URL: $BASE_URL"
fi

if [[ "$LAUNCH" == "1" ]]; then
  xcrun simctl launch booted "$BUNDLE_ID"
fi

echo "✓ done"
echo
echo "Note: the API key is stored in Keychain, which can't be seeded from outside."
echo "Open the Settings tab in the app and paste it manually the first time."
