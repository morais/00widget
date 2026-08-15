#!/usr/bin/env bash
# Archive, verify, and upload the iOS and tvOS apps to TestFlight.
#
# Both platforms run through one code path (`ship`), parameterised by a few
# values each. Keep it that way: if a fix is needed for one platform, express
# it as data in the `ship` call rather than a branch inside it.
#
# Why this script exists (lessons that cost real time doing it by hand):
#
# 1. App Store Connect rejects a build whose CFBundleVersion isn't higher than
#    the last upload, and the failure arrives *after* a full archive. Bump
#    first, then assert the number actually reached every plist, because a
#    mis-set project.yml silently produces a literal "1".
#
# 2. `aps-environment` reads `development` in the archive even for a Release
#    build. That is normal and not a bug: the *export* step re-signs with the
#    distribution profile and flips it to `production`. Verifying the archive
#    tells you nothing — only the exported IPA does. The same applies to
#    com.apple.developer.applesignin on tvOS, where a dropped entitlement means
#    Sign in with Apple fails at runtime on a build that installed fine.
#    com.apple.developer.associated-domains on iOS is the same class of trap,
#    and a quieter one: universal links just keep opening in Safari, and
#    Apple's CDN caches the wrong association for hours.
#
# 3. Automatic signing archives against a *development* profile, and Apple only
#    mints one for a platform that has a registered device. A team with
#    registered iPhones but no Apple TV can therefore archive iOS and not tvOS.
#    Register the device and both platforms archive with no configuration at
#    all. Note the UDID to register is the first value Xcode shows under
#    Identifier (the 25-character 8hex-16hex form), not the parenthesised
#    RFC-4122 UUID, which the Devices portal rejects.
#
#    ZW_TVOS_PROFILE / ZW_IOS_PROFILE remain an escape hatch for a machine that
#    cannot register a device: name a *manually managed* App Store profile.
#    Xcode-managed profiles are rejected under manual signing. Passing App Store
#    Connect credentials to `xcodebuild archive` does not help — they reach
#    Apple and Apple still declines without a registered device.
#
# Credentials are never read from this repository. The App Store Connect API
# key and its Issuer ID live under ~/.appstoreconnect, outside every checkout:
#
#   ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8   (chmod 600)
#   ~/.appstoreconnect/issuer_id                          (chmod 600)
#
# Override with ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID if you keep them
# elsewhere. Everything else — team id, bundle ids — is read from your
# gitignored ios/project.yml and the built app, so nothing identifying is
# hardcoded here.
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

if [[ "$UPLOAD" == "1" && ( ! -f "$ASC_KEY_PATH" || -z "$ASC_ISSUER_ID" ) ]]; then
  echo "App Store Connect credentials not found. Expected:"
  echo "  ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8"
  echo "  ~/.appstoreconnect/issuer_id      (Users and Access -> Integrations -> App Store Connect API)"
  echo "Or set ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID. Re-run with --verify-only to skip uploading."
  exit 1
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
for plist in Resources/App/Info.plist Resources/Widgets/Info.plist Resources/TV/Info.plist \
             Resources/Clip/Info.plist Resources/ClipWidgets/Info.plist; do
  [[ -f "$plist" ]] || continue
  got="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
  if [[ "$got" != '$(CURRENT_PROJECT_VERSION)' ]]; then
    echo "✗ $plist has CFBundleVersion '$got', expected \$(CURRENT_PROJECT_VERSION)"
    echo "  Fix ios/project.yml.sample and copy the change into ios/project.yml."
    exit 1
  fi
done

assert_build() { # <label> <plist>
  local got
  got="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$2" 2>/dev/null || true)"
  if [[ "$got" != "$BUILD_NUMBER" ]]; then
    echo "✗ $1 build number is '$got', expected $BUILD_NUMBER"
    exit 1
  fi
  echo "  ✓ $1 build number"
}

export_options() { # <path> <destination> <bundle-id> <profile-name-or-empty>
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>destination</key><string>$2</string>"
    echo '  <key>method</key><string>app-store-connect</string>'
    echo '  <key>manageAppVersionAndBuildNumber</key><false/>'
    echo '  <key>stripSwiftSymbols</key><true/>'
    echo '  <key>uploadSymbols</key><true/>'
    echo "  <key>teamID</key><string>$TEAM_ID</string>"
    if [[ -n "$4" ]]; then
      echo '  <key>signingStyle</key><string>manual</string>'
      echo '  <key>provisioningProfiles</key><dict>'
      echo "    <key>$3</key><string>$4</string>"
      echo '  </dict>'
    else
      echo '  <key>signingStyle</key><string>automatic</string>'
    fi
    echo '</dict></plist>'
  } > "$1"
}

# One path for every platform. Differences are arguments, not branches.
#   $1 label   $2 scheme   $3 destination   $4 product name
#   $5 ';'-separated entitlements the *signed* app must contain
#   $6 manually-managed profile name, empty for automatic signing
#   $7 optional ';'-separated bundles inside the app whose build numbers must
#      also match — extensions, and the App Clip with its own extension
ship() {
  local label="$1" scheme="$2" destination="$3" product="$4"
  local required_entitlements="$5" profile="$6" extra_bundle="${7:-}"
  local archive="$OUT/$product-$BUILD_NUMBER.xcarchive"
  local app="$archive/Products/Applications/$product.app"

  echo "→ [$label] archiving"
  rm -rf "$archive"
  local -a signing=()
  if [[ -n "$profile" ]]; then
    signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution"
             PROVISIONING_PROFILE_SPECIFIER="$profile")
  fi
  if ! xcodebuild archive \
        -project ZeroZeroWidget.xcodeproj -scheme "$scheme" -configuration Release \
        -destination "$destination" -archivePath "$archive" \
        -allowProvisioningUpdates \
        ${ASC_ISSUER_ID:+-authenticationKeyPath "$ASC_KEY_PATH"} \
        ${ASC_ISSUER_ID:+-authenticationKeyID "$ASC_KEY_ID"} \
        ${ASC_ISSUER_ID:+-authenticationKeyIssuerID "$ASC_ISSUER_ID"} \
        ${signing[@]+"${signing[@]}"} >"$OUT/$label-archive.log" 2>&1; then
    echo "✗ [$label] archive failed. Last lines:"
    grep -iE 'error' "$OUT/$label-archive.log" | head -5 | sed 's/^/    /'
    if [[ -z "$profile" ]] && grep -q 'no devices' "$OUT/$label-archive.log"; then
      echo "  Automatic signing needs a registered $label device to mint a development"
      echo "  profile. Register one, or set the profile env var to a manually managed"
      echo "  App Store profile (see the header of this script)."
    fi
    echo "  Full log: $OUT/$label-archive.log"
    exit 1
  fi

  echo "→ [$label] checking build numbers"
  local archive_build
  archive_build="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$archive/Info.plist" 2>/dev/null || true)"
  [[ "$archive_build" == "$BUILD_NUMBER" ]] || { echo "✗ [$label] archive build is '$archive_build', expected $BUILD_NUMBER"; exit 1; }
  echo "  ✓ archive build number"
  assert_build "$label app" "$app/Info.plist"
  local nested
  while IFS= read -r nested; do
    [[ -z "$nested" ]] && continue
    assert_build "$label $nested" "$app/$nested/Info.plist"
  done <<<"${extra_bundle//;/$'\n'}"

  # Only the re-signed export shows what TestFlight will actually receive.
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  echo "→ [$label] exporting locally to inspect the distribution signature"
  export_options "$OUT/$label-local.plist" export "$bundle_id" "$profile"
  rm -rf "$OUT/$label-local"
  # Deliberately no -authenticationKey* flags here, unlike the upload export
  # below. Those take precedence over the accounts configured in Xcode, and an
  # App Store Connect key without distribution-signing permission then fails
  # with "Cloud signing permission error" on a machine where the Xcode account
  # would have regenerated the profile happily. This step only needs a locally
  # signed IPA to inspect, so let Xcode's account do it.
  if ! xcodebuild -exportArchive -archivePath "$archive" \
      -exportOptionsPlist "$OUT/$label-local.plist" -exportPath "$OUT/$label-local" \
      -allowProvisioningUpdates >"$OUT/$label-export.log" 2>&1; then
    echo "✗ [$label] export failed. Last lines:"
    grep -iE 'error' "$OUT/$label-export.log" | head -5 | sed 's/^/    /'
    if grep -q "doesn't include the" "$OUT/$label-export.log"; then
      echo "  A profile is missing a capability the app now requests. Check the App"
      echo "  ID has it in the developer portal, then let Xcode regenerate the"
      echo "  *distribution* profile — it only does so during an export, not on"
      echo "  launch, and it needs an account in Xcode -> Settings -> Accounts."
    fi
    if grep -q "No Accounts" "$OUT/$label-export.log"; then
      echo "  No account in Xcode -> Settings -> Accounts to sign with. On a machine"
      echo "  that cannot have one, set ZW_$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]')_PROFILE to a manually managed"
      echo "  App Store profile instead."
    fi
    echo "  Full log: $OUT/$label-export.log"
    exit 1
  fi

  rm -rf "$OUT/$label-unzip" && mkdir -p "$OUT/$label-unzip"
  unzip -q "$OUT/$label-local/$product.ipa" -d "$OUT/$label-unzip"
  local entitlements
  entitlements="$(codesign -d --entitlements - --xml "$OUT/$label-unzip/Payload/$product.app" 2>/dev/null | plutil -p -)"
  # Report every missing entitlement, not just the first: one run should show
  # the whole picture rather than uncovering them one archive at a time.
  local missing=0 required
  while IFS= read -r required; do
    [[ -z "$required" ]] && continue
    if grep -qF "$required" <<<"$entitlements"; then
      echo "  ✓ signed app has $required"
    else
      echo "✗ [$label] signed app is missing: $required"
      missing=1
    fi
  done <<<"${required_entitlements//;/$'\n'}"
  if (( missing )); then
    echo "$entitlements" | sed 's/^/    /'
    exit 1
  fi

  # The App Clip is signed separately from the app that carries it, so the
  # checks above say nothing about it. Without parent-application-identifiers
  # the clip installs and refuses to launch; without associated-domains the QR
  # code opens Safari instead of the clip, which looks like nothing happening.
  local clip="$OUT/$label-unzip/Payload/$product.app/AppClips/ZeroZeroWidgetClip.app"
  if [[ -d "$clip" ]]; then
    local clip_entitlements
    clip_entitlements="$(codesign -d --entitlements - --xml "$clip" 2>/dev/null | plutil -p -)"
    local required
    for required in com.apple.developer.parent-application-identifiers \
                    com.apple.developer.associated-domains; do
      if grep -qF "$required" <<<"$clip_entitlements"; then
        echo "  ✓ signed App Clip has $required"
      else
        echo "✗ [$label] signed App Clip is missing: $required"
        echo "$clip_entitlements" | sed 's/^/    /'
        exit 1
      fi
    done
  fi

  if [[ "$UPLOAD" != "1" ]]; then
    echo "  (skipping upload: --verify-only)"
    return
  fi
  echo "→ [$label] uploading"
  export_options "$OUT/$label-upload.plist" upload "$bundle_id" "$profile"
  rm -rf "$OUT/$label-upload"
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$OUT/$label-upload.plist" -exportPath "$OUT/$label-upload" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

if [[ "$DO_IOS" == "1" ]]; then
  ship iOS ZeroZeroWidgetApp 'generic/platform=iOS' ZeroZeroWidgetApp \
    '"aps-environment" => "production";com.apple.developer.associated-domains' \
    "${ZW_IOS_PROFILE:-}" \
    "PlugIns/ZeroZeroWidgetWidgets.appex;AppClips/ZeroZeroWidgetClip.app;AppClips/ZeroZeroWidgetClip.app/PlugIns/ZeroZeroWidgetClipLiveActivity.appex"
fi

if [[ "$DO_TVOS" == "1" ]]; then
  ship tvOS ZeroZeroWidgetTV 'generic/platform=tvOS' ZeroZeroWidgetTV \
    'com.apple.developer.applesignin' "${ZW_TVOS_PROFILE:-}"
fi

echo "✓ done — build $BUILD_NUMBER"
echo "  artifacts: $OUT"
if [[ "$UPLOAD" == "1" ]]; then
  echo "  App Store Connect shows the build as Processing for a few minutes."
fi
echo
echo "ios/project.yml now pins CURRENT_PROJECT_VERSION=$BUILD_NUMBER (gitignored)."
