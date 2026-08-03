#!/usr/bin/env bash
# Archive, verify, and upload the iOS and tvOS apps to TestFlight.
#
# Why this script exists (lessons that cost real time doing it by hand):
#
# 1. App Store Connect rejects a build whose CFBundleVersion isn't higher than
#    the last upload, and the failure arrives *after* a full archive. Bump
#    first, then assert the number actually reached all three plists, because
#    a mis-set project.yml silently produces a literal "1".
#
# 2. `aps-environment` reads `development` in the archive even for a Release
#    build. That is normal and not a bug: the *export* step re-signs with the
#    distribution profile and flips it to `production`. Verifying the archive
#    tells you nothing — only the exported IPA does.
#
# 3. The tvOS target requires com.apple.developer.applesignin. A profile can
#    grant it while the final signature omits it, in which case Sign in with
#    Apple fails at runtime on a build that installed fine. Always export
#    locally and check the signed app before uploading.
#
# 4. tvOS automatic signing looks for a *development* profile and cannot mint
#    one without an Xcode account, so it fails where iOS succeeds. Point
#    ZW_TVOS_PROFILE at a manually-managed App Store profile instead. Xcode-
#    managed profiles are rejected under manual signing, so it must be one you
#    created yourself in the developer portal.
#
# Credentials are never read from this repository. The App Store Connect API
# key and its Issuer ID live under ~/.appstoreconnect, outside every checkout:
#
#   ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8   (chmod 600)
#   ~/.appstoreconnect/issuer_id                          (chmod 600)
#
# Override with ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID if you keep them
# elsewhere. Everything else — team id, bundle ids — is read from your
# gitignored ios/project.yml, so nothing identifying is hardcoded here.
#
# Usage:
#   ios/scripts/upload-testflight.sh                     # both platforms
#   ios/scripts/upload-testflight.sh --ios-only
#   ios/scripts/upload-testflight.sh --tvos-only
#   ios/scripts/upload-testflight.sh --verify-only       # build + gates, no upload
#   ios/scripts/upload-testflight.sh --build 202601011200

set -euo pipefail

DO_IOS=1
DO_TVOS=1
UPLOAD=1
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --ios-only) DO_TVOS=0; shift ;;
    --tvos-only) DO_IOS=0; shift ;;
    --verify-only) UPLOAD=0; shift ;;
    --build) BUILD_NUMBER="$2"; shift 2 ;;
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

TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' project.yml | head -1)"
if [[ -z "$TEAM_ID" ]]; then
  echo "DEVELOPMENT_TEAM is empty in ios/project.yml — set your Apple Developer Team ID."
  exit 1
fi

ASC_KEY_PATH="${ASC_KEY_PATH:-}"
if [[ -z "$ASC_KEY_PATH" ]]; then
  # Newest key wins if several are present.
  ASC_KEY_PATH="$(ls -t "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -1 || true)"
fi
ASC_KEY_ID="${ASC_KEY_ID:-}"
if [[ -z "$ASC_KEY_ID" && -n "$ASC_KEY_PATH" ]]; then
  ASC_KEY_ID="$(basename "$ASC_KEY_PATH" .p8)"
  ASC_KEY_ID="${ASC_KEY_ID#AuthKey_}"
fi
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
if [[ -z "$ASC_ISSUER_ID" && -f "$HOME/.appstoreconnect/issuer_id" ]]; then
  ASC_ISSUER_ID="$(tr -d '[:space:]' < "$HOME/.appstoreconnect/issuer_id")"
fi

if [[ "$UPLOAD" == "1" ]]; then
  if [[ ! -f "$ASC_KEY_PATH" || -z "$ASC_ISSUER_ID" ]]; then
    echo "App Store Connect credentials not found. Expected:"
    echo "  ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8"
    echo "  ~/.appstoreconnect/issuer_id      (Users and Access -> Integrations -> App Store Connect API)"
    echo "Or set ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID. Re-run with --verify-only to skip uploading."
    exit 1
  fi
fi

OUT="${ZW_TESTFLIGHT_OUT:-$(mktemp -d -t zw-testflight)}"
mkdir -p "$OUT"

echo "→ build number: $BUILD_NUMBER (team $TEAM_ID)"
python3 - "$BUILD_NUMBER" <<'PY'
import re, sys, pathlib
build = sys.argv[1]
p = pathlib.Path("project.yml")
s = p.read_text()
new, n = re.subn(r'CURRENT_PROJECT_VERSION: *"[^"]*"', f'CURRENT_PROJECT_VERSION: "{build}"', s)
if n != 1:
    sys.exit(f"expected exactly one CURRENT_PROJECT_VERSION in project.yml, found {n}")
p.write_text(new)
PY

echo "→ regenerating Xcode project"
xcodegen >/dev/null

# A generated plist holding a literal build number instead of the variable means
# App Store Connect will see "1" and reject the upload after a full archive.
for plist in Resources/App/Info.plist Resources/Widgets/Info.plist Resources/TV/Info.plist; do
  [[ -f "$plist" ]] || continue
  got="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
  if [[ "$got" != '$(CURRENT_PROJECT_VERSION)' ]]; then
    echo "✗ $plist has CFBundleVersion '$got', expected \$(CURRENT_PROJECT_VERSION)"
    echo "  Fix ios/project.yml.sample and copy the change into ios/project.yml."
    exit 1
  fi
done

assert_build() { # <label> <actual>
  if [[ "$2" != "$BUILD_NUMBER" ]]; then
    echo "✗ $1 is '$2', expected $BUILD_NUMBER"
    exit 1
  fi
  echo "  ✓ $1"
}

# Reads the signed entitlements of an app inside an exported .ipa.
signed_entitlements() { # <ipa> <app-name>
  local work="$OUT/unzip-$2"
  rm -rf "$work" && mkdir -p "$work"
  unzip -q "$1" -d "$work"
  codesign -d --entitlements - --xml "$work/Payload/$2.app" 2>/dev/null | plutil -p -
}

export_options() { # <path> <destination> [profile-key] [profile-name]
  local path="$1" dest="$2" bundle="${3:-}" profile="${4:-}"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>destination</key><string>$dest</string>"
    echo '  <key>method</key><string>app-store-connect</string>'
    echo '  <key>manageAppVersionAndBuildNumber</key><false/>'
    echo '  <key>stripSwiftSymbols</key><true/>'
    echo '  <key>uploadSymbols</key><true/>'
    echo "  <key>teamID</key><string>$TEAM_ID</string>"
    if [[ -n "$profile" ]]; then
      echo '  <key>signingStyle</key><string>manual</string>'
      echo '  <key>provisioningProfiles</key><dict>'
      echo "    <key>$bundle</key><string>$profile</string>"
      echo '  </dict>'
    else
      echo '  <key>signingStyle</key><string>automatic</string>'
    fi
    echo '</dict></plist>'
  } > "$path"
}

upload() { # <archive> <options-plist> <export-dir>
  xcodebuild -exportArchive \
    -archivePath "$1" -exportOptionsPlist "$2" -exportPath "$3" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

if [[ "$DO_IOS" == "1" ]]; then
  ARCHIVE="$OUT/ZeroZeroWidgetApp-$BUILD_NUMBER.xcarchive"
  echo "→ archiving iOS"
  rm -rf "$ARCHIVE"
  xcodebuild archive \
    -project ZeroZeroWidget.xcodeproj -scheme ZeroZeroWidgetApp -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates >/dev/null

  APP="$ARCHIVE/Products/Applications/ZeroZeroWidgetApp.app"
  EXT="$APP/PlugIns/ZeroZeroWidgetWidgets.appex"
  echo "→ checking build numbers"
  assert_build "archive"          "$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE/Info.plist")"
  assert_build "app bundle"       "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
  assert_build "widget extension" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXT/Info.plist")"

  # The archive says aps-environment=development even in Release; only the
  # re-signed export reveals what TestFlight will actually receive.
  echo "→ exporting locally to inspect the distribution signature"
  export_options "$OUT/ios-export-local.plist" export
  rm -rf "$OUT/ios-local"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ios-export-local.plist" -exportPath "$OUT/ios-local" \
    -allowProvisioningUpdates >/dev/null
  ENT="$(signed_entitlements "$OUT/ios-local/ZeroZeroWidgetApp.ipa" ZeroZeroWidgetApp)"
  if ! grep -q '"aps-environment" => "production"' <<<"$ENT"; then
    echo "✗ signed iOS app is not production-push. Entitlements were:"
    echo "$ENT"
    echo "  Push would silently fail on TestFlight. Check the distribution profile."
    exit 1
  fi
  echo "  ✓ aps-environment = production"

  if [[ "$UPLOAD" == "1" ]]; then
    echo "→ uploading iOS"
    export_options "$OUT/ios-export.plist" upload
    rm -rf "$OUT/ios-upload"
    upload "$ARCHIVE" "$OUT/ios-export.plist" "$OUT/ios-upload"
  else
    echo "  (skipping upload: --verify-only)"
  fi
fi

if [[ "$DO_TVOS" == "1" ]]; then
  ARCHIVE="$OUT/ZeroZeroWidgetTV-$BUILD_NUMBER.xcarchive"
  TV_BUNDLE_ID="$(sed -n '/ZeroZeroWidgetTV:/,$p' project.yml \
    | sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*\(.*\)/\1/p' | head -1)"
  TV_PROFILE="${ZW_TVOS_PROFILE:-}"

  echo "→ archiving tvOS"
  rm -rf "$ARCHIVE"
  if [[ -n "$TV_PROFILE" ]]; then
    xcodebuild archive \
      -project ZeroZeroWidget.xcodeproj -scheme ZeroZeroWidgetTV -configuration Release \
      -destination 'generic/platform=tvOS' -archivePath "$ARCHIVE" \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="Apple Distribution" \
      PROVISIONING_PROFILE_SPECIFIER="$TV_PROFILE" >/dev/null
  else
    # Works only if a tvOS development profile already exists locally or an
    # Xcode account can create one; otherwise set ZW_TVOS_PROFILE.
    xcodebuild archive \
      -project ZeroZeroWidget.xcodeproj -scheme ZeroZeroWidgetTV -configuration Release \
      -destination 'generic/platform=tvOS' -archivePath "$ARCHIVE" \
      -allowProvisioningUpdates >/dev/null
  fi

  TVAPP="$ARCHIVE/Products/Applications/ZeroZeroWidgetTV.app"
  echo "→ checking build numbers"
  assert_build "archive"    "$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE/Info.plist")"
  assert_build "app bundle" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TVAPP/Info.plist")"

  echo "→ exporting locally to inspect the distribution signature"
  export_options "$OUT/tv-export-local.plist" export "$TV_BUNDLE_ID" "$TV_PROFILE"
  rm -rf "$OUT/tv-local"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/tv-export-local.plist" -exportPath "$OUT/tv-local" >/dev/null
  ENT="$(signed_entitlements "$OUT/tv-local/ZeroZeroWidgetTV.ipa" ZeroZeroWidgetTV)"
  if ! grep -q 'com.apple.developer.applesignin' <<<"$ENT"; then
    echo "✗ signed tvOS app is missing com.apple.developer.applesignin. Entitlements were:"
    echo "$ENT"
    echo "  Sign in with Apple would fail at runtime. Enable the capability on the"
    echo "  App ID and regenerate the profile before uploading."
    exit 1
  fi
  echo "  ✓ com.apple.developer.applesignin present"

  if [[ "$UPLOAD" == "1" ]]; then
    echo "→ uploading tvOS"
    export_options "$OUT/tv-export.plist" upload "$TV_BUNDLE_ID" "$TV_PROFILE"
    rm -rf "$OUT/tv-upload"
    upload "$ARCHIVE" "$OUT/tv-export.plist" "$OUT/tv-upload"
  else
    echo "  (skipping upload: --verify-only)"
  fi
fi

echo "✓ done — build $BUILD_NUMBER"
echo "  artifacts: $OUT"
if [[ "$UPLOAD" == "1" ]]; then
  echo "  App Store Connect shows the build as Processing for a few minutes."
fi
echo
echo "ios/project.yml now pins CURRENT_PROJECT_VERSION=$BUILD_NUMBER (gitignored)."
