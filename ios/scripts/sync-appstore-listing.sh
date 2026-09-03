#!/bin/bash
# Sync or verify every App Store Connect listing asset managed by this repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE=""

usage() {
  cat <<'EOF'
Usage: ios/scripts/sync-appstore-listing.sh [--dry-run | --apply | --verify-only]

Store the canonical URL in gitignored ios/appstore.env, or use:
  ZW_APPCLIP_INVOCATION_URL=https://api.example.com/app/g \
    ios/scripts/sync-appstore-listing.sh --verify-only

The default run applies the canonical metadata, App Clip card, and screenshot sets.
EOF
}

case "${1:-}" in
  "") ;;
  --dry-run|--apply|--verify-only) MODE="$1" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

METADATA_MODE="${MODE:---apply}"
"$SCRIPT_DIR/sync-appstore-metadata.py" "$METADATA_MODE"

# The existing helpers use an argument-free invocation for apply mode.
if [[ "$MODE" == "--dry-run" || "$MODE" == "--verify-only" ]]; then
  "$SCRIPT_DIR/sync-appclip-default-experience.py" "$MODE"
  "$SCRIPT_DIR/upload-appstore-screenshots.py" "$MODE"
else
  "$SCRIPT_DIR/sync-appclip-default-experience.py"
  "$SCRIPT_DIR/upload-appstore-screenshots.py"
fi
