#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# `delta` anchors the bars at zero rather than at the bottom of the range, so a
# signed series reads as up/down rather than as more/less. Zero is always in the
# plotted range unless both `min` and `max` are pinned away from it.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "grid-balance",
    "template": "chart",
    "title": "Grid",
    "subtitle": "Net kWh, last 10 hours",
    "value": "+1.8",
    "unit": "kWh",
    "status": "good",
    "icon": "bolt.horizontal",
    "chart": {
      "points": [-2.4, -1.9, -0.6, 0.8, 2.2, 3.1, 2.7, 1.4, -0.3, 1.8],
      "style": "delta"
    }
  }'
echo
