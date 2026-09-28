#!/bin/bash
# Capture a Horizon Store screenshot straight to the clipboard as an image.
#
# Thin wrapper around capture-screenshots.sh that defaults to
# --clipboard image. All arguments are passed through, and an explicit
# --clipboard <mode> overrides the default.
#
# Usage:
#   capture-screenshot-to-clipboard.sh [--out DIR] [--prefix NAME] ...
#
# Examples:
#   capture-screenshot-to-clipboard.sh
#   capture-screenshot-to-clipboard.sh --prefix dashboard
#   capture-screenshot-to-clipboard.sh --clipboard path --count 3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for arg in "$@"; do
    if [ "$arg" = "--clipboard" ]; then
        exec "$SCRIPT_DIR/capture-screenshots.sh" "$@"
    fi
done

exec "$SCRIPT_DIR/capture-screenshots.sh" --clipboard image "$@"
