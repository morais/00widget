#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# A moving headline with a full recent window. `chart` wins the main visual
# space while `progress` still supplies an informative ring when iOS collapses
# the activity to its minimal presentation. Item rows are deliberately omitted:
# active items would replace the chart on the Lock Screen and Dynamic Island.
curl -sS -X POST "$BASE_URL/v1/live-activities/start" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "externalActivityId": "humidity-trend-1",
    "kind": "progress",
    "title": "Humidity trend",
    "subtitle": "Last 14 readings",
    "state": "monitoring",
    "signal": "caution",
    "icon": "humidity",
    "statusIcon": "chart.line.uptrend.xyaxis",
    "value": "65",
    "unit": "%",
    "progress": 0.65,
    "chart": {
      "points": [57, 59, 61, 60, 64, 67, 70, 68, 73, 71, 69, 66, 64, 65],
      "min": 40,
      "max": 80,
      "reference": 60,
      "referenceMetadata": {
        "label": "Comfort limit",
        "semantic": {"role": "target"}
      },
      "semantic": {"role": "actual", "signal": "caution"},
      "style": "line",
      "labels": [
        "-65m", "-60m", "-55m", "-50m", "-45m", "-40m", "-35m",
        "-30m", "-25m", "-20m", "-15m", "-10m", "-5m", "Now"
      ]
    },
    "relevanceScore": 1,
    "alert": {
      "title": "Humidity trend",
      "body": "The latest humidity chart is ready"
    }
  }'
echo
