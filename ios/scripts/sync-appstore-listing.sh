#!/bin/bash
# Sync or verify every App Store Connect listing asset managed by this repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE=""

usage() {
  cat <<'EOF'
Usage: ios/scripts/sync-appstore-listing.sh [--dry-run | --verify-only]

Store the canonical URL in gitignored ios/appstore.env, or use:
  ZW_APPCLIP_INVOCATION_URL=https://api.example.com/app/g \
    ios/scripts/sync-appstore-listing.sh --verify-only

The default run syncs the App Clip card and all canonical screenshot sets.
EOF
}

case "${1:-}" in
  "") ;;
  --dry-run|--verify-only) MODE="$1" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

"$SCRIPT_DIR/sync-appclip-default-experience.py" ${MODE:+"$MODE"}
"$SCRIPT_DIR/upload-appstore-screenshots.py" ${MODE:+"$MODE"}
