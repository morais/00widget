# Host checks shared by the scripts that drive a device through metavr.
# Sourced, not run: `. "$SCRIPT_DIR/metavr-preflight.sh"`, then call
# metavr_preflight. Prints each problem with its fix and exits non-zero;
# silent when everything is in place.
#
# Both checks cover failures metavr reports badly or not at all:
#
# - metavr's own `adb` subcommands use a built-in client, so shell,
#   install, and `device list` all work without an adb binary. File
#   transfer does not: `capture screenshot` shells out to an external adb
#   to pull the image, and with none found it fails with a bare "IO error:
#   No such file or directory", naming neither adb nor the pull.
# - metavr never creates ~/.android/adbkey. Without it every run signs
#   with a fresh random key, so the headset treats each run as a new
#   computer and asks for USB debugging permission again, however many
#   times "Always allow" is ticked. The only symptom on the host is a WARN
#   line that the capture scripts hide.

metavr_preflight() {
    local problems=0

    if ! command -v metavr >/dev/null; then
        echo "metavr not found on PATH" >&2
        echo "  Install the Meta VR CLI: https://developers.meta.com/horizon/" >&2
        return 1
    fi

    # `config get` prints the resolved path first, whether configured or
    # auto-detected. (`config list` shows it only on a terminal.)
    local adb
    adb="$(metavr config get adb-path 2>/dev/null | head -n 1 || true)"
    case "$adb" in /*) ;; *) adb="" ;; esac
    if [ -z "$adb" ] || [ ! -x "$adb" ]; then
        echo "No adb executable for metavr (adb_path: ${adb:-none found})." >&2
        echo "  metavr needs one to pull captures off the device; without it" >&2
        echo "  a capture fails with 'IO error: No such file or directory'." >&2
        echo "  Fix: brew install --cask android-platform-tools" >&2
        echo "   or: metavr config set adb-path /path/to/platform-tools/adb" >&2
        problems=1
    fi

    if [ ! -s "$HOME/.android/adbkey" ]; then
        echo "No ADB key at ~/.android/adbkey." >&2
        echo "  metavr signs every run with a new random key, so the device" >&2
        echo "  asks to allow USB debugging each time and 'Always allow' never" >&2
        echo "  sticks. Create a permanent key, then approve it once on the device:" >&2
        echo "  Fix: mkdir -p ~/.android && chmod 700 ~/.android && \\" >&2
        echo "       openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \\" >&2
        echo "         -out ~/.android/adbkey && chmod 600 ~/.android/adbkey" >&2
        problems=1
    fi

    return "$problems"
}
