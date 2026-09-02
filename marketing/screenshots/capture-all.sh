#!/usr/bin/env bash
# Captures, composes, and verifies every App Store marketing screenshot set.
#
#   marketing/screenshots/capture-all.sh
#   marketing/screenshots/capture-all.sh --verify-only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RAW_ROOT="$REPO_ROOT/artifacts/screenshots/raw"
VERIFY_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-only) VERIFY_ONLY=true; shift ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

CAPTURE_STARTED_AT=""
if [[ "$VERIFY_ONLY" == false ]]; then
  CAPTURE_STARTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  echo "→ capturing iPhone 6.3-inch set"
  "$SCRIPT_DIR/capture-ios.sh" --device "iPhone 17 Pro"

  echo "→ capturing iPhone 6.5-inch set"
  "$SCRIPT_DIR/capture-ios.sh" --device "iPhone 14 Plus – App Store 6.5"

  echo "→ capturing iPad set"
  "$SCRIPT_DIR/capture-ios.sh" --device "iPad Pro 13-inch (M4)"

  echo "→ capturing Apple TV set"
  "$SCRIPT_DIR/capture-tvos.sh"
fi

echo "→ verifying all canonical screenshot sets"
python3 - "$RAW_ROOT" "$CAPTURE_STARTED_AT" <<'PY'
import datetime
import hashlib
import json
import os
import struct
import sys

root, started_at = sys.argv[1:]
started = None
if started_at:
    started = datetime.datetime.fromisoformat(started_at.replace("Z", "+00:00"))

ios_files = {
    "screenshot-activities.png",
    "screenshot-home-insights.png",
    "screenshot-home-metrics.png",
    "screenshot-home-widgets.png",
    "screenshot-insights.png",
    "screenshot-widgets.png",
}
tv_files = {
    "screenshot-tv-card-detail.png",
    "screenshot-tv-insights.png",
    "screenshot-tv-widgets.png",
}
sets = {
    "iphone-6.3": ("iPhone 17 Pro", (1206, 2622), ios_files),
    "iphone-6.5": ("iPhone 14 Plus – App Store 6.5", (1284, 2778), ios_files),
    "ipad": ("iPad Pro 13-inch (M4)", (2064, 2752), ios_files),
    "tvos": ("Apple TV 4K (3rd generation) (at 1080p)", (1920, 1080), tv_files),
}

errors = []
for set_name, (expected_device, expected_size, required_files) in sets.items():
    directory = os.path.join(root, set_name)
    manifest_path = os.path.join(directory, ".capture-manifest.json")
    try:
        with open(manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"{set_name}: cannot read capture manifest: {error}")
        continue

    if manifest.get("mode") != "all":
        errors.append(f"{set_name}: manifest mode is not 'all'")
    if manifest.get("device") != expected_device:
        errors.append(
            f"{set_name}: expected device {expected_device!r}, "
            f"found {manifest.get('device')!r}"
        )

    try:
        captured = datetime.datetime.fromisoformat(manifest["capturedAt"])
        if started is not None and captured < started:
            errors.append(f"{set_name}: manifest was not produced by this workflow run")
    except (KeyError, TypeError, ValueError):
        errors.append(f"{set_name}: manifest has an invalid capturedAt value")

    manifest_files = manifest.get("files", {})
    if set(manifest_files) != required_files:
        missing = sorted(required_files - set(manifest_files))
        extra = sorted(set(manifest_files) - required_files)
        errors.append(f"{set_name}: manifest file mismatch; missing={missing}, extra={extra}")

    disk_files = {
        name
        for name in os.listdir(directory)
        if name.startswith("screenshot-") and name.endswith(".png")
    }
    if disk_files != required_files:
        missing = sorted(required_files - disk_files)
        extra = sorted(disk_files - required_files)
        errors.append(f"{set_name}: output file mismatch; missing={missing}, extra={extra}")

    for name in sorted(required_files & disk_files):
        path = os.path.join(directory, name)
        with open(path, "rb") as handle:
            data = handle.read()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
            errors.append(f"{set_name}/{name}: invalid PNG")
            continue
        size = struct.unpack(">II", data[16:24])
        if size != expected_size:
            errors.append(
                f"{set_name}/{name}: expected {expected_size[0]}x{expected_size[1]}, "
                f"found {size[0]}x{size[1]}"
            )
        expected_hash = manifest_files.get(name)
        actual_hash = hashlib.md5(data).hexdigest()
        if expected_hash != actual_hash:
            errors.append(f"{set_name}/{name}: checksum differs from capture manifest")

    print(f"  {set_name}: {len(required_files)} screenshots at {expected_size[0]}x{expected_size[1]}")

if errors:
    print("Screenshot workflow verification failed:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    raise SystemExit(1)

print("✓ all four canonical screenshot sets verified")
PY

if [[ "$VERIFY_ONLY" == false ]]; then
  echo "→ generating all promotional screenshot compositions"
  python3.12 "$SCRIPT_DIR/generate-promotional.py" \
    --generated-after "$CAPTURE_STARTED_AT"
else
  echo "→ verifying all promotional screenshot compositions"
  python3.12 "$SCRIPT_DIR/generate-promotional.py" --verify-only
fi

echo "✓ full marketing screenshot workflow complete: 21 raw captures + 21 promotional compositions"
