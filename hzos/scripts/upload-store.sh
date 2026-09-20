#!/bin/bash
# Build the signed release and upload it to a Horizon Store release channel.
#
# Secrets come from gitignored hzos/store.properties (see
# store.properties.sample), with environment overrides for CI:
#   META_APP_SECRET   Dashboard → app → API tab (or a user token). Required.
#   KEYSTORE_FILE / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD
#                     Release signing. Required.
#   META_APP_ID       Defaults to platformAppId in hzos/local.properties.
#
# Usage:
#   upload-store.sh --channel ALPHA --age-group MIXED_AGES [--notes "..."] [--draft] [--skip-build]
#
# Channels: ALPHA / BETA / RC for testing, STORE for production. Age group is
# a self-certification (TEENS_AND_ADULTS | MIXED_AGES | CHILDREN) — no silent
# default, pass it explicitly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HZOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OVR_UTIL="${OVR_UTIL_BIN:-$HOME/.local/bin/ovr-platform-util}"

# Load store.properties allowlist into the environment without overriding
# anything already exported (env wins, so CI keeps working).
if [ -f "$HZOS_DIR/store.properties" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            META_APP_SECRET|KEYSTORE_FILE|KEYSTORE_PASSWORD|KEY_ALIAS|KEY_PASSWORD)
                if [ -z "${!key:-}" ] && [ -n "$value" ]; then export "$key=$value"; fi
                ;;
        esac
    done < <(grep -vE '^\s*(#|$)' "$HZOS_DIR/store.properties")
fi
# Gradle reads ZW_-prefixed env for signing; mirror the file values there.
export ZW_KEYSTORE_FILE="${ZW_KEYSTORE_FILE:-${KEYSTORE_FILE:-}}"
export ZW_KEYSTORE_PASSWORD="${ZW_KEYSTORE_PASSWORD:-${KEYSTORE_PASSWORD:-}}"
export ZW_KEY_ALIAS="${ZW_KEY_ALIAS:-${KEY_ALIAS:-}}"
export ZW_KEY_PASSWORD="${ZW_KEY_PASSWORD:-${KEY_PASSWORD:-}}"
export ZW_META_APP_SECRET="${ZW_META_APP_SECRET:-${META_APP_SECRET:-}}"

CHANNEL=""
AGE_GROUP=""
NOTES="00Widget for Horizon OS"
DRAFT=""
SKIP_BUILD=""
APP_ID_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --age-group) AGE_GROUP="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        --draft) DRAFT="--draft"; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --app-id) APP_ID_OVERRIDE="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | cut -c3-
            exit 0
            ;;
        *) echo "Unknown flag: $1 (see --help)" >&2; exit 1 ;;
    esac
done

[ -n "$CHANNEL" ] || { echo "Missing --channel (ALPHA|BETA|RC|STORE)" >&2; exit 1; }
[ -n "$AGE_GROUP" ] || { echo "Missing --age-group (TEENS_AND_ADULTS|MIXED_AGES|CHILDREN)" >&2; exit 1; }
[ -n "${ZW_META_APP_SECRET:-}" ] || { echo "Set ZW_META_APP_SECRET (Dashboard API tab)" >&2; exit 1; }
[ -n "${ZW_KEYSTORE_FILE:-}" ] || { echo "Set ZW_KEYSTORE_FILE (+ PASSWORD/ALIAS, see README)" >&2; exit 1; }
[ -x "$OVR_UTIL" ] || { echo "ovr-platform-util not found at $OVR_UTIL (OVR_UTIL_BIN overrides)" >&2; exit 1; }

APP_ID="$APP_ID_OVERRIDE"
if [ -z "$APP_ID" ] && [ -f "$HZOS_DIR/local.properties" ]; then
    APP_ID="$(grep -E '^platformAppId=' "$HZOS_DIR/local.properties" | cut -d= -f2 | tr -d '[:space:]')"
fi
[ -n "$APP_ID" ] || { echo "No app id: set platformAppId in hzos/local.properties or pass --app-id" >&2; exit 1; }

if [ -z "$SKIP_BUILD" ]; then
    echo "Building signed release..."
    (cd "$HZOS_DIR" && ./gradlew :app:assembleRelease --console=plain)
fi

APK="$HZOS_DIR/app/build/outputs/apk/release/app-release.apk"
[ -f "$APK" ] || { echo "APK not found at $APK" >&2; exit 1; }

echo "Uploading $APK to channel $CHANNEL..."
DRAFT_FLAG=()
if [ -n "$DRAFT" ]; then DRAFT_FLAG=(--draft); fi
"$OVR_UTIL" upload-quest-build \
    --app-id "$APP_ID" \
    --app-secret "$ZW_META_APP_SECRET" \
    --apk "$APK" \
    --channel "$CHANNEL" \
    --age-group "$AGE_GROUP" \
    --notes "$NOTES" \
    "${DRAFT_FLAG[@]}" \
    --disable-progress-bar
