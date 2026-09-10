#!/usr/bin/env bash
# Resolves which simulator UI host to drive: Simulator.app on Xcode 26,
# DeviceHub.app on Xcode 27 where Simulator.app no longer exists.
#
# Source it (never execute it):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=sim-app.sh
#   source "$SCRIPT_DIR/sim-app.sh"
#
# Then call `open_sim_app` instead of `open -a Simulator`, and `pgrep -x
# "$SIM_APP"` (or `sim_app_running`) instead of `pgrep -x Simulator`.
# AppleScript callers pass "$SIM_APP" as an extra osascript argument and
# `tell application simApp` / `tell process simApp` — both forms accept a
# variable — so one code path drives either generation.
#
# Resolution prefers Simulator.app, so an Xcode 26 machine keeps its exact old
# behavior; DeviceHub is used only when Simulator.app is not installed. Any
# other launch failure still errors rather than masking itself behind the
# fallback.

# Resolved by resolve_sim_app/open_sim_app; defaults to the Xcode 26 name so
# callers can reference $SIM_APP (e.g. pgrep) before resolving.
SIM_APP="Simulator"

# Sets SIM_APP without launching anything: the running host when there is
# one (the capture scripts open it before any preflight runs), otherwise
# the default — open_sim_app resolves on launch. Prefers DeviceHub when it
# is the one running; on a single-generation machine the check is
# unambiguous either way.
resolve_sim_app() {
  if pgrep -x DeviceHub >/dev/null; then
    SIM_APP="DeviceHub"
  elif pgrep -x Simulator >/dev/null; then
    SIM_APP="Simulator"
  fi
}

# Opens the simulator UI host, optionally with extra `open` arguments (e.g.
# --args -CurrentDeviceUDID <udid>). Sets SIM_APP to the app that launched.
open_sim_app() {
  local err
  for SIM_APP in Simulator DeviceHub; do
    if err="$(open -a "$SIM_APP" "$@" 2>&1)"; then
      return 0
    fi
    case "$err" in
      *"Unable to find application"*) continue ;;
      *)
        printf '%s\n' "$err" >&2
        return 1
        ;;
    esac
  done
  echo "✗ neither Simulator.app nor DeviceHub.app is installed" >&2
  return 1
}

# True when the resolved simulator UI host is running.
sim_app_running() {
  pgrep -x "$SIM_APP" >/dev/null
}
