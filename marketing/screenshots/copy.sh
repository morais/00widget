#!/usr/bin/env bash
# Copies the canonical marketing screenshot set into any website asset folder.
#
#   marketing/screenshots/copy.sh --set iphone-6.3 --to /path/to/site/public/assets
#   marketing/screenshots/copy.sh --set iphone-6.5 --to /path/to/site/public/assets
#   marketing/screenshots/copy.sh --only activities --to /path/to/site/public/assets
#   marketing/screenshots/copy.sh --set ipad --to /path/to/site/public/assets/ipad
#   marketing/screenshots/copy.sh --set tvos --to /path/to/site/public/assets/tvos
set -euo pipefail

SET="iphone"
ONLY="all"
DESTINATION=""

usage() {
  sed -n '2,5p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --set) SET="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --to) DESTINATION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$ONLY" != "all" && "$ONLY" != "activities" ]]; then
  echo "--only must be 'all' or 'activities'" >&2
  exit 2
fi

if [[ -z "$DESTINATION" ]]; then
  echo "--to is required; pass the website's asset directory explicitly" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "$SET" in
  iphone|iphone-6.3) SOURCE="$REPO_ROOT/artifacts/screenshots/promotional/iphone-6.3" ;;
  iphone-6.5) SOURCE="$REPO_ROOT/artifacts/screenshots/promotional/iphone-6.5" ;;
  ipad) SOURCE="$REPO_ROOT/artifacts/screenshots/promotional/ipad" ;;
  tvos) SOURCE="$REPO_ROOT/artifacts/screenshots/promotional/tvos" ;;
  *) echo "--set must be 'iphone-6.3', 'iphone-6.5', 'ipad', or 'tvos'" >&2; exit 2 ;;
esac

if [[ "$SET" == "tvos" ]]; then
  if [[ "$ONLY" != "all" ]]; then
    echo "--only activities is not available for tvOS" >&2
    exit 2
  fi
  FILES=(screenshot-tv-insights.png screenshot-tv-widgets.png screenshot-tv-card-detail.png)
elif [[ "$ONLY" == "activities" ]]; then
  FILES=(screenshot-activities.png)
else
  FILES=(
    screenshot-home-widgets.png
    screenshot-home-insights.png
    screenshot-lock-activity.png
    screenshot-home-metrics.png
    screenshot-widgets.png
    screenshot-insights.png
    screenshot-activities.png
  )
fi

for file in "${FILES[@]}"; do
  if [[ ! -f "$SOURCE/$file" ]]; then
    echo "missing $SOURCE/$file; run marketing/screenshots/capture-all.sh first" >&2
    exit 1
  fi
done

mkdir -p "$DESTINATION"
for file in "${FILES[@]}"; do
  cp "$SOURCE/$file" "$DESTINATION/$file"
  echo "  $DESTINATION/$file"
done

echo "✓ copied $SET $ONLY marketing screenshots"
