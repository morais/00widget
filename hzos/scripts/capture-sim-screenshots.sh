#!/bin/bash
# Capture clean, straight hzos panel screenshots on Meta Spatial Simulator.
#
# The simulator draws panels flat in 2D, so unlike a headset capture there
# is no head tilt or perspective. This script:
#   1. starts the simulator if needed and installs the current debug build,
#   2. turns off the simulator's Show Interactive Elements overlay and
#      switches it to light mode (restored on exit),
#   3. sets the app's Developer screen for screenshots: Hide sample
#      indicators on, so demo data has no SAMPLE badges or samples banner
#      (generating demo data first when there is none), and Card opacity at
#      100%, so the launcher's app tiles don't show through the cards,
#   4. captures the dashboard, one Ongoing Activity popped out into its own
#      panel, and one widget card popped out into its own panel.
#
# The simulator opens a popped-out panel on top of the dashboard, so the
# dashboard's window stack is removed before each pop-out shot and the
# dashboard reopened afterwards. Card opacity stays at 100% afterwards; set
# it back in Developer > Look if you want the glass look.
#
# Output: gitignored artifacts/screenshots/raw/hzos/ (see --out). The
# simulator's display is 2064x2208, so crop for the store's 2560x1440.
#
# Usage:
#   capture-sim-screenshots.sh [--device ID] [--out DIR] [--card TITLE]
#                              [--skip-build]
#
# --card picks the widget to pop out by its title (default: Trials, the
# sample chart card). Everything is tapped by label or resource id, never by
# screen position, except the simulator's own settings gear, which is fixed
# chrome in its top-left corner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HZOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$HZOS_DIR/.." && pwd)"
DEVICE="emulator-5554"
OUT="$REPO_ROOT/artifacts/screenshots/raw/hzos"
CARD="Trials"
SKIP_BUILD=""
PACKAGE="com.zerozerowidget.hzos"
APK="$HZOS_DIR/app/build/outputs/apk/debug/app-debug.apk"

while [ $# -gt 0 ]; do
    case "$1" in
        --device|-d) DEVICE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --card) CARD="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --help|-h)
            grep '^#' "$0" | cut -c3-
            exit 0
            ;;
        *) echo "Unknown flag: $1 (see --help)" >&2; exit 1 ;;
    esac
done

command -v metavr >/dev/null || { echo "metavr not found on PATH" >&2; exit 1; }
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$OUT"

m() { metavr -d "$DEVICE" "$@"; }

# The UI dump as JSON; every query below reads it through query().
query() {
    # $1 = python expression over `els` (a flat list of elements, each with
    # a `parent` link); prints whatever it returns, nothing for None.
    m ui dump --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
els = []
def walk(n, parent=None):
    n['parent'] = parent
    els.append(n)
    for c in n.get('children', []):
        walk(c, n)
for e in d['elements']:
    walk(e)
def label(n):
    return n.get('content_desc') or n.get('text') or ''
r = $1
if r is not None:
    print(r if not isinstance(r, (list, tuple)) else ' '.join(map(str, r)))
"
}

wait_for() {
    # $1 = python condition over `els`, $2 = what we're waiting for.
    for _ in $(seq 1 20); do
        [ "$(query "True if ($1) else None")" = "True" ] && return 0
        sleep 1
    done
    echo "Timed out waiting for $2" >&2
    exit 1
}

focused() { m window list 2>/dev/null | grep -F "[FOCUS]" | head -1; }

shot() {
    FILE="$OUT/sim-$1-$(date +%Y%m%d-%H%M%S).png"
    m capture screenshot --method screencap -o "$FILE" >/dev/null
    echo "Captured $FILE"
}

# 1. Simulator up, current build installed and opened as the launcher does.
if ! metavr device list 2>/dev/null | grep -q "^$DEVICE *device"; then
    echo "Starting Spatial Simulator..."
    (metavr tools launch spatialsim >/dev/null 2>&1 &)
    for _ in $(seq 1 60); do
        [ "$(m adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
        sleep 5
    done
fi
[ "$(m adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] ||
    { echo "Simulator $DEVICE did not boot" >&2; exit 1; }

if [ -z "$SKIP_BUILD" ]; then
    echo "Building debug APK..."
    if [ -z "${JAVA_HOME:-}" ] && [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
        export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    fi
    (cd "$HZOS_DIR" && ./gradlew -q :app:assembleDebug)
fi
[ -f "$APK" ] || { echo "No APK at $APK (drop --skip-build)" >&2; exit 1; }
m adb install -r "$APK" >/dev/null
m adb shell am force-stop "$PACKAGE"
m adb shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
    -f 0x10200000 -n "$PACKAGE/.DashboardActivity" >/dev/null
sleep 5

# 2. Light mode, restored on exit; simulator overlay off (the toggle
# reports `checked` only when on).
NIGHT_BEFORE="$(m adb shell cmd uimode night 2>/dev/null | sed -n 's/^Night mode: //p' | tr -d '\r')"
trap '[ -n "$NIGHT_BEFORE" ] && m adb shell cmd uimode night "$NIGHT_BEFORE" >/dev/null 2>&1' EXIT
m adb shell cmd uimode night no >/dev/null
m adb shell input tap 92 92   # the simulator's own settings gear: fixed chrome, and its id is only in the dump once its window has focus
wait_for "any(n.get('resource_id') == 'settings_close_button' for n in els)" "simulator settings"
if [ "$(query "True if any(n.get('resource_id') == 'settings_gaze_debug_indicators_toggle' and n.get('checked') for n in els) else None")" = "True" ]; then
    m ui tap --id settings_gaze_debug_indicators_toggle >/dev/null
    echo "Turned off Show Interactive Elements."
fi
m ui tap --id settings_close_button >/dev/null
sleep 2

# 3. Demo data present, and its badges hidden.
for button in "Try demo data" "Generate samples"; do
    if [ "$(query "True if any(label(n) == '$button' for n in els) else None")" = "True" ]; then
        m ui tap --text "$button" >/dev/null
        echo "Generated demo data."
        sleep 3
        break
    fi
done

m ui tap --content-desc Settings >/dev/null
wait_for "any(label(n) == 'Close' for n in els)" "app Settings"
# The version row opens Developer. Match "Version <name> (" so a sample
# activity's "Version 2.4 · five steps" never matches too.
VERSION_NAME="$(sed -n 's/.*versionName = "\([^"]*\)".*/\1/p' "$HZOS_DIR/app/build.gradle.kts" | head -1)"
m ui tap --text "Version $VERSION_NAME (" >/dev/null
wait_for "any(label(n) == 'Hide sample indicators' for n in els)" "Developer settings"
# Compose reports the switch's state on its row, the parent of the label.
if [ "$(query "True if any(n.get('content_desc') == 'Hide sample indicators' and (n.get('checked') or (n['parent'] or {}).get('checked')) for n in els) else None")" != "True" ]; then
    m ui tap --content-desc "Hide sample indicators" >/dev/null
    echo "Turned on Hide sample indicators."
fi
# Card opacity: drag the slider under its heading past its right end.
m ui scroll-to-find --text "Card opacity" --exact >/dev/null 2>&1 || true
SLIDER="$(query "next((n['bounds'] for n in els if n.get('class') == 'android.widget.SeekBar'), None)")"
[ -n "$SLIDER" ] || { echo "No Card opacity slider on the Developer screen" >&2; exit 1; }
read -r SX0 SY0 SX1 SY1 <<< "$SLIDER"
SY=$(( (SY0 + SY1) / 2 ))
m ui swipe --from "$(( (SX0 + SX1) / 2 )),$SY" --to "$(( SX1 + 40 )),$SY" >/dev/null
wait_for "any('passthrough: 100%' in n.get('text', '') for n in els)" "Card opacity at 100%"
echo "Card opacity at 100%."
m ui tap --content-desc Close >/dev/null
sleep 3

# 4. The three shots.
shot dashboard

# The pop-out button on the same row as a title, left of it being the title.
tap_popout_for() {
    # $1 = python condition picking the title element `t`.
    XY="$(query "next((f\"{p['center'][0]},{p['center'][1]}\" for t in els if ($1) for p in els if p.get('content_desc') == 'Pop out' and abs(p['center'][1] - t['center'][1]) < 60 and p['center'][0] > t['center'][0]), None)")"
    [ -n "$XY" ] || return 1
    m ui tap --coords "$XY" >/dev/null
}

open_dashboard() {
    m adb shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \
        -f 0x10200000 -n "$PACKAGE/.DashboardActivity" >/dev/null
    wait_for "any(n.get('text') == 'Widgets' for n in els)" "the dashboard"
}

# The window stack (root task) holding an activity, from `am stack list`.
stack_of() {
    m adb shell am stack list 2>/dev/null | awk -v a="$1" '/RootTask id=/{id=$2} index($0, a){sub("id=", "", id); print id; exit}'
}

open_panel_and_shoot() {
    # $1 = shot name. Waits for the detail panel, removes the dashboard
    # behind it, shoots, closes the panel and reopens the dashboard.
    for _ in $(seq 1 15); do
        focused | grep -q "CardDetailActivity" && break
        sleep 1
    done
    focused | grep -q "CardDetailActivity" || { echo "No detail panel opened for $1" >&2; exit 1; }
    DASH_STACK="$(stack_of "$PACKAGE/$PACKAGE.DashboardActivity")"
    [ -z "$DASH_STACK" ] || m adb shell am stack remove "$DASH_STACK"
    sleep 3
    shot "$1"
    DETAIL_STACK="$(stack_of "$PACKAGE/$PACKAGE.CardDetailActivity")"
    [ -z "$DETAIL_STACK" ] || m adb shell am stack remove "$DETAIL_STACK"
    open_dashboard
}

# The first activity: its title sits above the Widgets heading.
WIDGETS_Y="$(query "next((n['center'][1] for n in els if n.get('text') == 'Widgets'), None)")"
[ -n "$WIDGETS_Y" ] || { echo "No Widgets heading on the dashboard" >&2; exit 1; }
tap_popout_for "t.get('text') and t['center'][1] < $WIDGETS_Y and any(n.get('text') == 'Ongoing Activities' and n['center'][1] < t['center'][1] for n in els)" ||
    { echo "No Ongoing Activity to pop out" >&2; exit 1; }
open_panel_and_shoot activity

# Widgets are a scrolled list: bring the card into view first.
m ui scroll-to-find --text "$CARD" --exact >/dev/null 2>&1 || true
sleep 1
tap_popout_for "t.get('text') == '$CARD'" ||
    { echo "No widget titled '$CARD' on screen (see --card)" >&2; exit 1; }
open_panel_and_shoot card

echo "Done: 3 screenshots in $OUT"
