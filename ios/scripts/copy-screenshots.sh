#!/usr/bin/env bash
# Copies the canonical marketing screenshot set into any website asset folder.
#
#   ios/scripts/copy-screenshots.sh --to /path/to/site/public/assets
#   ios/scripts/copy-screenshots.sh --only activities --to /path/to/site/public/assets
#   ios/scripts/copy-screenshots.sh --set ipad --to /path/to/site/public/assets/ipad
#   ios/scripts/copy-screenshots.sh --set tvos --to /path/to/site/public/assets/tvos
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

IOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$SET" in
  iphone) SOURCE="$IOS_ROOT/build/screenshots" ;;
  ipad) SOURCE="$IOS_ROOT/build/screenshots/ipad" ;;
  tvos) SOURCE="$IOS_ROOT/build/screenshots/tvos" ;;
  *) echo "--set must be 'iphone', 'ipad', or 'tvos'" >&2; exit 2 ;;
esac

if [[ "$SET" == "tvos" ]]; then
  if [[ "$ONLY" == "activities" ]]; then
    FILES=(screenshot-tv-activities.png)
  else
    FILES=(screenshot-tv-widgets.png screenshot-tv-insights.png screenshot-tv-activities.png)
  fi
elif [[ "$ONLY" == "activities" ]]; then
  FILES=(screenshot-activities.png)
else
  FILES=(
    screenshot-widgets.png
    screenshot-home-widgets.png
    screenshot-activities.png
    screenshot-insights.png
    screenshot-breakdown.png
    screenshot-home-insights.png
  )
fi

for file in "${FILES[@]}"; do
  if [[ ! -f "$SOURCE/$file" ]]; then
    echo "missing $SOURCE/$file; capture the $SET screenshots first" >&2
    exit 1
  fi
done

mkdir -p "$DESTINATION"
for file in "${FILES[@]}"; do
  cp "$SOURCE/$file" "$DESTINATION/$file"
  echo "  $DESTINATION/$file"
done

echo "✓ copied $SET $ONLY marketing screenshots"
