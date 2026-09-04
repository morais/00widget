#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# `comparison` is the change drawn under the headline value: where the number
# is, and which way it is moving. Both halves are formatted by you — the device
# never computes a delta.
#
# `signal` is what the change *means*, not which way it points. +18 trials is
# favorable; +18 errors would be unfavorable, and -12% spend favorable again.
# Pick it from the reading, or the card draws a green arrow over bad news.
# Omitting it draws the change neutral.
#
# This is unrelated to a chart's `delta` style, which controls bar geometry.
# The card below carries both a comparison and a chart.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "trial-signups",
    "template": "chart",
    "title": "Trials",
    "subtitle": "Started this week",
    "value": "128",
    "unit": "today",
    "status": "good",
    "icon": "chart.line.uptrend.xyaxis",
    "producer": { "label": "Growth Agent", "icon": "sparkles" },
    "comparison": { "value": "+18", "label": "vs Monday", "signal": "favorable" },
    "chart": {
      "points": [110, 111, 114, 116, 119, 123, 128],
      "min": 108,
      "max": 130,
      "reference": 110,
      "referenceMetadata": { "label": "Monday", "semantic": { "role": "baseline" } },
      "semantic": { "role": "actual", "signal": "favorable" },
      "style": "line",
      "labels": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Today"]
    }
  }'
echo
