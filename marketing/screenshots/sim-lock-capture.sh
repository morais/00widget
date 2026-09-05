#!/usr/bin/env bash
# Locks one iOS Simulator through its accessibility tree and captures the
# Lock Screen framebuffer for static marketing shots.
#
# Why this exists: XCUITest runs on-device and can stage a Live Activity, but
# it cannot lock the simulator and `XCUIScreen.main.screenshot()` never shows
# the Lock Screen. The host can: it selects the intended Simulator window via
# accessibility, invokes Simulator → Device → Lock through the accessibility
# menu (never screen coordinates), waits for the Live Activity presentation to
# settle, and captures the framebuffer with `simctl io screenshot`.
#
# Coordination with the UI test is file-based — both run on the same Mac, so
# the test stages the activity, writes $HANDSHAKE_DIR/ready, and polls for
# $HANDSHAKE_DIR/done while this script locks, captures, and answers:
#
#   marketing/screenshots/sim-lock-capture.sh \
#     --device "iPhone 17 Pro" \
#     --handshake-dir /tmp/zw-lock-xxx \
#     --out artifacts/screenshots/raw/iphone-6.3/screenshot-lock-activity.png
#
#   marketing/screenshots/sim-lock-capture.sh --preflight-only --device "iPhone 17 Pro"
#
# Unlock is restored with `simctl launch`, which wakes the device out of the
# Lock Screen without any gesture tooling.
set -euo pipefail

DEVICE=""
UDID=""
OUT=""
HANDSHAKE_DIR=""
TIMEOUT=150
SETTLE=20
BUNDLE_ID="com.00widget.app"
PREFLIGHT_ONLY=false
NO_RESTORE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --udid) UDID="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --handshake-dir) HANDSHAKE_DIR="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --preflight-only) PREFLIGHT_ONLY=true; shift ;;
    --no-restore) NO_RESTORE=true; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DEVICE" && -z "$UDID" ]]; then
  echo "--device or --udid is required" >&2
  exit 2
fi
if [[ "$PREFLIGHT_ONLY" == false ]]; then
  if [[ -z "$OUT" ]]; then echo "--out is required" >&2; exit 2; fi
  if [[ -z "$HANDSHAKE_DIR" ]]; then echo "--handshake-dir is required" >&2; exit 2; fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_BUILD_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)/ios/build"

# Resolve the UDID for a simulator display name. Prefers the booted match so a
# second runtime holding the same name cannot steal the capture.
resolve_udid() {
  xcrun simctl list -j devices | python3 -c '
import json, sys
want = sys.argv[1]
payload = json.load(sys.stdin)
hits = []
for runtime, devices in payload["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("name") == want and device.get("isAvailable", True):
            hits.append(device)
if not hits:
    sys.exit("no available iOS simulator named " + repr(want))
booted = [d for d in hits if d.get("state") == "Booted"]
pick = booted[0] if len(booted) == 1 else (hits[0] if len(hits) == 1 else None)
if pick is None:
    names = ", ".join(d["udid"] + " (" + d["state"] + ")" for d in hits)
    sys.exit("ambiguous device name " + repr(want) + ": " + names + " -- pass --udid")
print(pick["udid"])
' "$1"
}

ax_probe_error_hint() {
  local detail="$1"
  local parent="your terminal"
  if [[ -n "${TERM_PROGRAM:-}" ]]; then parent="$TERM_PROGRAM"; fi
  local invoker
  invoker="$(ps -o comm= -p "$PPID" 2>/dev/null || true)"
  if [[ -n "$invoker" ]]; then parent="$invoker (via $parent)"; fi
  cat >&2 <<EOF
✗ The lock-screen adapter cannot drive Simulator.app: macOS denied the
  accessibility request.

  This script locks the simulator through the accessibility tree
  (System Events → Simulator → Device → Lock), which needs Accessibility
  permission for the app running it: $parent.

  Fix: System Settings → Privacy & Security → Accessibility → enable the
  toggle for that app, then re-run. If it is already enabled, remove and
  re-add it — macOS sometimes loses the grant on app updates.

  Underlying error: $detail
EOF
}

# Brings up the device window for $DEVICE when Simulator.app is running without
# one. Closing a device window (Cmd-W) leaves the app running and the device
# booted, and `open -a Simulator` will not bring the window back — but the
# Window menu still lists the device, so clicking that entry restores it.
summon_device_window() {
  osascript - "$DEVICE" <<'EOF' >/dev/null 2>&1
on run argv
  set deviceName to item 1 of argv
  tell application "Simulator" to activate
  tell application "System Events"
    tell process "Simulator"
      tell menu 1 of menu bar item "Window" of menu bar 1
        repeat with idx from 1 to (count of menu items)
          try
            if name of menu item idx starts with deviceName then
              click menu item idx
              return "ok"
            end if
          end try
        end repeat
      end tell
    end tell
  end tell
  error "no Window-menu entry for " & deviceName
end run
EOF
}

device_window_count() {
  osascript - "$DEVICE" <<'EOF' 2>/dev/null || echo 0
on run argv
  set deviceName to item 1 of argv
  tell application "System Events"
    tell process "Simulator"
      set found to 0
      repeat with w in (every window)
        try
          if name of w starts with deviceName then set found to found + 1
        end try
      end repeat
      return found as text
    end tell
  end tell
end run
EOF
}

# The device screen's position and size in Mac screen points, so a point in
# the captured framebuffer can be turned into a point to click. The AXGroup
# inside the device window is the screen itself; the scale follows from the
# capture's own width, which keeps 2x devices (iPad) and 3x ones (iPhone) on
# the same code path.
device_screen_frame() {
  osascript - "$DEVICE" <<'EOF' 2>/dev/null
on run argv
  set deviceName to item 1 of argv
  tell application "System Events"
    tell process "Simulator"
      repeat with w in (every window)
        try
          if name of w starts with deviceName then
            set g to (first UI element of w whose role is "AXGroup")
            set p to position of g
            set z to size of g
            return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ((item 1 of z) as text) & " " & ((item 2 of z) as text)
          end if
        end try
      end repeat
    end tell
  end tell
  error "no window for " & deviceName
end run
EOF
}

# Answers the Live Activities consent prompt if this capture caught one.
#
# iOS raises it the first time an app's activity is presented on a Lock
# Screen, and periodically afterwards, drawn inside the activity's own
# presentation — so it lands in the capture, and an App Store screenshot may
# not contain a system permission prompt. It cannot be pre-granted, is never
# presented while the device is unlocked, and a locked device takes no
# XCUITest input, so the only way past it is to click it like a person. See
# lock_consent.py for how the button is found.
answer_consent_prompt() {
  local capture="$1"
  local point
  point="$(python3 "$SCRIPT_DIR/lock_consent.py" "$capture" 2>/dev/null || echo none)"
  if [[ "$point" == "none" || -z "$point" ]]; then
    return 1
  fi

  local frame
  if ! frame="$(device_screen_frame)"; then
    echo "  consent prompt found but the device window vanished" >&2
    return 1
  fi

  local tap="$IOS_BUILD_DIR/sim-tap"
  if [[ ! -x "$tap" || "$SCRIPT_DIR/sim-tap.swift" -nt "$tap" ]]; then
    mkdir -p "$IOS_BUILD_DIR"
    if ! swiftc -O -o "$tap" "$SCRIPT_DIR/sim-tap.swift"; then
      echo "  could not build the tap helper" >&2
      return 1
    fi
  fi

  local screen
  if ! screen="$(python3 - "$capture" "$point" "$frame" <<'EOF'
import sys
from PIL import Image

capture, point, frame = sys.argv[1], sys.argv[2], sys.argv[3]
px, py = (int(v) for v in point.split())
ox, oy, gw, gh = (float(v) for v in frame.split())
with Image.open(capture) as image:
    scale = image.width / gw
print(f"{ox + px / scale:.0f} {oy + py / scale:.0f}")
EOF
)"; then
    return 1
  fi

  # Raise the target window first. A synthesised click goes to whatever is
  # on top at that screen point, and a machine that has captured several
  # device sets has several overlapping Simulator windows: the first attempt
  # answered the 6.3 prompt, whose window happened to be frontmost, and
  # silently missed on the two behind it.
  osascript - "$DEVICE" <<'EOF' >/dev/null 2>&1 || true
on run argv
  set deviceName to item 1 of argv
  tell application "Simulator" to activate
  tell application "System Events"
    tell process "Simulator"
      repeat with w in (every window)
        try
          if name of w starts with deviceName then
            perform action "AXRaise" of w
            exit repeat
          end if
        end try
      end repeat
    end tell
  end tell
end run
EOF
  sleep 1

  echo "  answering the Live Activities consent prompt (device $point)"
  "$tap" $screen || return 1
  sleep 3
  return 0
}

# Preflight: Simulator.app reachable AND scriptable through accessibility. The
# probe reads Simulator's Device menu — the same surface the lock step clicks —
# so a pass means the lock step can run, and a failure names the fix.
#
# The menu bar is not the whole precondition, though: `ax_lock` raises the
# device *window* before clicking Device → Lock, and a Simulator running with
# no window has a full menu bar and zero windows. That combination passed
# preflight and failed the lock with a message telling the operator to re-run
# the preflight — which passed again. So the window is checked here too, and
# restored when it can be.
preflight() {
  if ! pgrep -x Simulator >/dev/null; then
    echo "→ opening Simulator.app for preflight"
    open -a Simulator
    for _ in {1..20}; do
      if pgrep -x Simulator >/dev/null; then break; fi
      sleep 0.25
    done
  fi
  if ! pgrep -x Simulator >/dev/null; then
    echo "✗ Simulator.app did not launch" >&2
    exit 1
  fi
  local probe_err
  if probe_err="$(osascript -e 'tell application "System Events" to tell process "Simulator" to get count of menu items of menu 1 of menu bar item "Device" of menu bar 1' 2>&1)"; then
    if [[ "$(device_window_count)" == "0" ]]; then
      echo "→ no window for $DEVICE; restoring it from the Window menu"
      summon_device_window || true
      for _ in {1..20}; do
        [[ "$(device_window_count)" != "0" ]] && break
        sleep 0.5
      done
    fi
    if [[ "$(device_window_count)" == "0" ]]; then
      cat >&2 <<EOF
✗ Simulator.app is running but has no window for $DEVICE, and the Window menu
  did not restore one. The lock step raises that window before clicking
  Device → Lock, so it cannot proceed.

  Fix: bring the simulator window up by hand — Simulator → Window → $DEVICE,
  or quit Simulator.app and re-run. A Mac whose screen is locked also hides
  windows from the accessibility tree; unlock it first.
EOF
      exit 1
    fi
    echo "✓ Simulator accessibility preflight passed"
  else
    if printf '%s' "$probe_err" | grep -qiE "assistive access|accessib|not allowed|-25211|-1719|operation not permitted"; then
      ax_probe_error_hint "$probe_err"
      exit 3
    fi
    echo "✗ Simulator accessibility probe failed: $probe_err" >&2
    exit 1
  fi
}

# Click Simulator → Device → Lock without touching screen coordinates. The Lock
# item carries no accessibility name on some Xcode builds (it still carries the
# ⌘L equivalent), so fall back to the ⌘L item when the named lookup misses.
ax_lock() {
  osascript - "$DEVICE" <<'EOF' 2>&1
on run argv
  set deviceName to item 1 of argv
  tell application "Simulator" to activate
  tell application "System Events"
    tell process "Simulator"
      -- Front the intended simulator: Device-menu commands act on whichever
      -- device window is selected, so never assume it already is.
      set targetWindow to missing value
      repeat with w in (every window)
        try
          if name of w starts with deviceName then
            set targetWindow to w
            exit repeat
          end if
        end try
      end repeat
      if targetWindow is missing value then
        error "no Simulator window for device " & deviceName
      end if
      perform action "AXRaise" of targetWindow
      delay 0.5
      set didLock to false
      try
        click menu item "Lock" of menu 1 of menu bar item "Device" of menu bar 1
        set didLock to true
      on error
        -- Unnamed on some builds; the ⌘L equivalent still identifies it.
        tell menu 1 of menu bar item "Device" of menu bar 1
          repeat with idx from 1 to (count of menu items)
            try
              if value of attribute "AXMenuItemCmdChar" of menu item idx is "L" then
                click menu item idx
                set didLock to true
                exit repeat
              end if
            end try
          end repeat
        end tell
      end try
      if didLock is false then
        error "Device menu has no Lock item on this Xcode build"
      end if
    end tell
  end tell
end run
EOF
}

# Wake a dark display back to the Lock Screen, again through accessibility:
# raising the window plus Device → Home wakes without unlocking.
ax_wake_to_lock() {
  osascript - "$DEVICE" <<'EOF' 2>&1
on run argv
  set deviceName to item 1 of argv
  tell application "Simulator" to activate
  tell application "System Events"
    tell process "Simulator"
      repeat with w in (every window)
        try
          if name of w starts with deviceName then
            perform action "AXRaise" of w
            exit repeat
          end if
        end try
      end repeat
      delay 0.5
      click menu item "Home" of menu 1 of menu bar item "Device" of menu bar 1
    end tell
  end tell
end run
EOF
}

# Mean framebuffer brightness from the PNG stdlib-only (zlib + struct), so the
# adapter gains no dependency. Returns 0-255; prints -1 when undecodable.
mean_brightness() {
  python3 - "$1" <<'PY'
import struct, sys, zlib

def chunks(data):
    pos = 8
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        yield kind, data[pos + 8:pos + 8 + length]
        pos += 12 + length

try:
    path = sys.argv[1]
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        print(-1)
        raise SystemExit  # module level: `return` would be a SyntaxError here
    width = height = ctype = depth = None
    raw = b""
    for kind, body in chunks(data):
        if kind == b"IHDR":
            width, height, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            raw += body
    if width is None or depth != 8 or ctype not in (0, 2, 4, 6):
        print(-1)
        raise SystemExit  # module level: `return` would be a SyntaxError here
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    stride = width * channels
    pixels = zlib.decompress(raw)
    total = count = 0
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        f = pixels[pos]
        pos += 1
        line = bytearray(pixels[pos:pos + stride])
        pos += stride
        if f == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        prev = line
        step = channels
        total += sum(line[0::step]) + sum(line[1::step]) + sum(line[2::step]) if channels >= 3 else sum(line[0::step])
        count += width * (3 if channels >= 3 else 1)
    print(total / max(1, count))
except Exception:
    print(-1)
PY
}

fail_done() {
  printf 'error: %s\n' "$1" > "$HANDSHAKE_DIR/done"
  echo "✗ $1" >&2
  exit 1
}

if [[ -z "$UDID" ]]; then
  echo "→ resolving simulator UDID for $DEVICE"
  UDID="$(resolve_udid "$DEVICE")"
fi
DEVICE_STATE="$(xcrun simctl list -j devices | python3 -c "
import json, sys
for devices in json.load(sys.stdin)['devices'].values():
    for d in devices:
        if d.get('udid') == '$UDID':
            print(d.get('name', '') + '|' + d.get('state', ''))
")"
if [[ -z "$DEVICE_STATE" ]]; then
  echo "✗ unknown simulator UDID: $UDID" >&2
  exit 1
fi
DEVICE="${DEVICE_STATE%%|*}"
if [[ "${DEVICE_STATE##*|}" != "Booted" ]]; then
  echo "→ booting $DEVICE ($UDID)"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
fi

preflight
if [[ "$PREFLIGHT_ONLY" == true ]]; then exit 0; fi

mkdir -p "$HANDSHAKE_DIR"
rm -f "$HANDSHAKE_DIR/done"

echo "→ waiting for the UI test to stage the Live Activity"
deadline=$((SECONDS + TIMEOUT))
while [[ ! -f "$HANDSHAKE_DIR/ready" ]]; do
  if ((SECONDS >= deadline)); then
    fail_done "timed out after ${TIMEOUT}s waiting for the UI test marker ($HANDSHAKE_DIR/ready)"
  fi
  sleep 1
done

echo "→ locking $DEVICE through Simulator → Device → Lock"
if ! ax_lock; then
  fail_done "accessibility lock failed — re-run with --preflight-only for the fix"
fi

echo "→ waiting for the Lock Screen presentation to settle"
sleep 4
PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR"' EXIT
PROBE="$PROBE_DIR/probe.png"
dark_wake_tried=false
settle_deadline=$((SECONDS + SETTLE))
prev_hash=""
while true; do
  xcrun simctl io "$UDID" screenshot --type=png "$PROBE" 2>/dev/null || true
  brightness="$(mean_brightness "$PROBE")"
  if python3 -c "import sys; sys.exit(0 if float('$brightness') >= 0 and float('$brightness') < 8 else 1)" 2>/dev/null; then
    if [[ "$dark_wake_tried" == false ]]; then
      echo "  framebuffer is dark — waking to the Lock Screen"
      ax_wake_to_lock || true
      dark_wake_tried=true
      sleep 3
      continue
    fi
    fail_done "framebuffer stayed dark — the display slept and the wake did not recover it"
  fi
  hash="$(md5 -q "$PROBE" 2>/dev/null || md5sum "$PROBE" 2>/dev/null | cut -d' ' -f1 || true)"
  if [[ -n "$hash" && -n "$prev_hash" && "$hash" == "$prev_hash" ]]; then
    break
  fi
  prev_hash="$hash"
  if ((SECONDS >= settle_deadline)); then
    echo "  presentation still animating after ${SETTLE}s — capturing anyway"
    break
  fi
  sleep 2
done

# Capture to a staging file and only move it into place once it has passed
# every check. Writing $OUT directly means a run that fails afterwards leaves
# its failure in the canonical tree — a mis-aimed click produced a screenshot
# of the *app* under the Lock Screen capture's name, which the manifest would
# then have happily checksummed.
STAGED="$PROBE_DIR/capture.png"
echo "→ capturing $OUT"
xcrun simctl io "$UDID" screenshot --type=png "$STAGED"

# A capture holding a system permission prompt is not an asset, and the
# manifest would pass one happily — it checks filenames, checksums and
# dimensions, not what is in the picture. So answer the prompt and shoot
# again.
#
# Success is proved by *change*, not by re-running the detector on the result.
# The detector is good enough to aim a click — it found the button on three
# devices and both wording variants — but it also fires on a clean capture,
# where an activity's own rows are two bright clusters in a dark band just as
# the buttons are. Asking it whether the prompt is gone therefore fails a
# capture that is perfectly good, which is what it did to the 6.5-inch set
# after correctly dismissing its prompt.
#
# The brightness guard is the safety catch. A dismissed prompt barely moves
# the frame; a click that lands on the activity instead opens the app, and an
# app is far brighter than a Lock Screen. Refusing a large change keeps a
# mis-aimed click from being mistaken for success.
if answer_consent_prompt "$STAGED"; then
  before_brightness="$(mean_brightness "$STAGED")"
  before_hash="$(md5 -q "$STAGED" 2>/dev/null || md5sum "$STAGED" | cut -d' ' -f1)"
  echo "  re-capturing without the prompt"
  xcrun simctl io "$UDID" screenshot --type=png "$STAGED"
  after_brightness="$(mean_brightness "$STAGED")"
  after_hash="$(md5 -q "$STAGED" 2>/dev/null || md5sum "$STAGED" | cut -d' ' -f1)"
  if [[ "$before_hash" == "$after_hash" ]]; then
    fail_done "the consent prompt did not respond to the click at the button it was found at"
  fi
  if ! python3 -c "
import sys
before, after = float('$before_brightness'), float('$after_brightness')
sys.exit(0 if before <= 0 or abs(after - before) / before <= 0.35 else 1)
"; then
    fail_done "the screen changed too much after the click — it probably opened the app rather than answering the prompt"
  fi
fi
if ! python3 -c "
import sys
data = open('$STAGED','rb').read()
sys.exit(0 if data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) > 50000 else 1)
"; then
  fail_done "capture produced an invalid or empty PNG"
fi
mv "$STAGED" "$OUT"
printf 'ok\n' > "$HANDSHAKE_DIR/done"

if [[ "$NO_RESTORE" == false ]]; then
  echo "→ restoring the unlocked state"
  if ! xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "  warning: relaunch of $BUNDLE_ID failed — the simulator is still locked" >&2
  fi
fi

echo "✓ lock-screen capture in $OUT"
