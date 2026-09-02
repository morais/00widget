#!/usr/bin/env bash
# Capture and render an App Store Preview from a prepared iOS Simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "$ROOT/marketing/app-preview/tools/capture.py" "$@"
