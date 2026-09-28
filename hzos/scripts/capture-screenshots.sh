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
#                          [--clipboard off|path|image]
#
# --clipboard copies the result to the clipboard: `path` copies the file
# path(s) as text (newline-separated when --count > 1), `image` copies the
# image itself (the last shot when --count > 1). The image format is read
# from the file's magic bytes, not its extension. macOS uses pbcopy /
# AppleScript; on Linux, path needs xclip, xsel, or wl-copy and image
# needs xclip.
#
# Examples:
#   capture-screenshots.sh
#   capture-screenshots.sh --prefix dashboard --count 3 --interval 5
#   capture-screenshots.sh --out /tmp/shots --width 2560 --height 1440
#   capture-screenshots.sh --clipboard image
#   capture-screenshots.sh --clipboard path --count 3
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
CLIPBOARD="off"

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
        --clipboard) CLIPBOARD="$2"; shift 2 ;;
        --help|-h)
            grep '^#' "$0" | cut -c3-
            exit 0
            ;;
        *) echo "Unknown flag: $1 (see --help)" >&2; exit 1 ;;
    esac
done

case "$CLIPBOARD" in
    off|none|path|image) ;;
    *) echo "Unknown --clipboard mode: $CLIPBOARD (want off|path|image)" >&2; exit 1 ;;
esac

# Resolve --out to an absolute path so a copied path pastes anywhere.
case "$OUT" in
    /*) ;;
    *) OUT="$PWD/$OUT" ;;
esac

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

copy_paths_to_clipboard() {
    # $1 = newline-separated file list (no trailing newline).
    if command -v pbcopy >/dev/null; then
        printf '%s' "$1" | pbcopy
    elif command -v wl-copy >/dev/null; then
        printf '%s' "$1" | wl-copy
    elif command -v xclip >/dev/null; then
        printf '%s' "$1" | xclip -selection clipboard
    elif command -v xsel >/dev/null; then
        printf '%s' "$1" | xsel --clipboard --input
    else
        echo "WARNING: no clipboard tool found (pbcopy, wl-copy, xclip, xsel)" >&2
        return 1
    fi
}

image_kind() {
    # $1 = image file. Prints png|jpeg|unknown from magic bytes: metavr's
    # capture names everything .png even when the bytes are JPEG, so the
    # extension cannot be trusted.
    MAGIC="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
    case "$MAGIC" in
        89504e47*) printf 'png' ;;
        ffd8ff*) printf 'jpeg' ;;
        *) printf 'unknown' ;;
    esac
}

copy_image_to_clipboard() {
    # $1 = image file. The clipboard holds one image, so callers pass
    # the shot they want pasted.
    KIND="$(image_kind "$1")"
    case "$(uname)" in
        Darwin)
            # Escape for an AppleScript double-quoted string. The class
            # must match the bytes: JPEG tagged as PNGf pastes as nothing,
            # and osascript still exits 0, so a wrong guess looks like
            # success. (PNGf round-trips byte-identical, verified with cmp;
            # `as PNG picture` osascript rejects.)
            ESCAPED="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
            case "$KIND" in
                png) osascript -e "set the clipboard to (read (POSIX file \"$ESCAPED\") as «class PNGf»)" ;;
                jpeg) osascript -e "set the clipboard to (read (POSIX file \"$ESCAPED\") as JPEG picture)" ;;
                *) echo "WARNING: $1 is not PNG or JPEG, skipping clipboard" >&2; return 1 ;;
            esac
            ;;
        *)
            case "$KIND" in
                png) MIME="image/png" ;;
                jpeg) MIME="image/jpeg" ;;
                *) echo "WARNING: $1 is not PNG or JPEG, skipping clipboard" >&2; return 1 ;;
            esac
            if command -v xclip >/dev/null; then
                xclip -selection clipboard -t "$MIME" -i "$1"
            else
                echo "WARNING: image clipboard needs xclip on Linux" >&2
                return 1
            fi
            ;;
    esac
}

CAPTURED=""
for i in $(seq 1 "$COUNT"); do
    STAMP="$(date +%Y%m%d-%H%M%S)"
    if [ "$COUNT" -gt 1 ]; then
        FILE="$OUT/${PREFIX}-${STAMP}-$(printf '%02d' "$i").png"
    else
        FILE="$OUT/${PREFIX}-${STAMP}.png"
    fi
    echo "Capturing $i/$COUNT -> $FILE (${WIDTH}x${HEIGHT}, $METHOD)..."
    capture_one "$FILE"
    if [ -z "$CAPTURED" ]; then
        CAPTURED="$FILE"
    else
        CAPTURED="$CAPTURED
$FILE"
    fi
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

case "$CLIPBOARD" in
    path)
        copy_paths_to_clipboard "$CAPTURED" && echo "Copied path(s) to clipboard."
        ;;
    image)
        # The clipboard holds a single image: keep the most recent shot.
        LAST="$CAPTURED"
        case "$LAST" in
            *"
"*) LAST="$(printf '%s\n' "$LAST" | tail -n 1)" ;;
        esac
        copy_image_to_clipboard "$LAST" && echo "Copied image to clipboard: $LAST"
        # Prove the bytes actually landed: osascript exits 0 even when the
        # class tag doesn't match the content, so report clipboard info.
        case "$(uname)" in
            Darwin)
                INFO="$(osascript -e 'clipboard info' 2>/dev/null || true)"
                echo "Clipboard now holds: $(printf '%s' "$INFO" | cut -c1-200)"
                ;;
        esac
        ;;
esac

echo "Done: $COUNT screenshot(s) in $OUT"
