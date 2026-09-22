#!/bin/bash
# Capture Horizon Store screenshots from the connected Quest device.
#
# Wraps `metavr capture screenshot` at the store listing size (2560x1440
# by default). Output lands in gitignored artifacts/screenshots/raw/hzos/
# unless --out points elsewhere.
#
# Usage:
#   capture-screenshots.sh [--out DIR] [--prefix NAME] [--count N]
#                          [--interval SECS] [--width PX] [--height PX]
#                          [--method metacam|screencap] [--device ID]
#
# Examples:
#   capture-screenshots.sh
#   capture-screenshots.sh --prefix dashboard --count 3 --interval 5
#   capture-screenshots.sh --out /tmp/shots --width 2560 --height 1440
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$REPO_ROOT/artifacts/screenshots/raw/hzos"
PREFIX="screenshot"
COUNT=1
INTERVAL=3
WIDTH=2560
HEIGHT=1440
METHOD="metacam"
DEVICE="${HZDB_DEVICE:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --count) COUNT="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --width) WIDTH="$2"; shift 2 ;;
        --height) HEIGHT="$2"; shift 2 ;;
        --method) METHOD="$2"; shift 2 ;;
        --device|-d) DEVICE="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | cut -c3-
            exit 0
            ;;
        *) echo "Unknown flag: $1 (see --help)" >&2; exit 1 ;;
    esac
done

command -v metavr >/dev/null || { echo "metavr not found on PATH" >&2; exit 1; }
mkdir -p "$OUT"

# An asleep display captures at the panel's native size (or fails), ignoring
# --width/--height. Wake first so the requested size is what we get.
if [ -n "$DEVICE" ]; then
    metavr device wake --device "$DEVICE" >/dev/null 2>&1 || true
else
    metavr device wake >/dev/null 2>&1 || true
fi
sleep 1

capture_one() {
    # $1 = output file. --device only passed when set (metavr also
    # reads HZDB_DEVICE itself), keeping this portable to macOS /bin/bash.
    if [ -n "$DEVICE" ]; then
        metavr capture screenshot \
            --device "$DEVICE" \
            --width "$WIDTH" --height "$HEIGHT" \
            --method "$METHOD" \
            --output "$1"
    else
        metavr capture screenshot \
            --width "$WIDTH" --height "$HEIGHT" \
            --method "$METHOD" \
            --output "$1"
    fi
}

for i in $(seq 1 "$COUNT"); do
    STAMP="$(date +%Y%m%d-%H%M%S)"
    if [ "$COUNT" -gt 1 ]; then
        FILE="$OUT/${PREFIX}-${STAMP}-$(printf '%02d' "$i").png"
    else
        FILE="$OUT/${PREFIX}-${STAMP}.png"
    fi
    echo "Capturing $i/$COUNT -> $FILE (${WIDTH}x${HEIGHT}, $METHOD)..."
    capture_one "$FILE"
    # Verify the store format; sips ships with macOS, skip elsewhere.
    if command -v sips >/dev/null; then
        GOT="$(sips -g pixelWidth -g pixelHeight "$FILE" 2>/dev/null | awk '/pixel(Width|Height)/ {printf "%sx", $2}')"
        GOT="${GOT%x}"
        if [ "$GOT" != "${WIDTH}x${HEIGHT}" ]; then
            echo "WARNING: got ${GOT}, wanted ${WIDTH}x${HEIGHT} (display asleep?)" >&2
        fi
    fi
    if [ "$i" -lt "$COUNT" ]; then
        echo "Waiting ${INTERVAL}s... (rearrange panels for the next shot)"
        sleep "$INTERVAL"
    fi
done

echo "Done: $COUNT screenshot(s) in $OUT"
