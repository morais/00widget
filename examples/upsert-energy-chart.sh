#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# A `chart` card carries no history of its own: publish the whole window,
# oldest point first, every time it moves.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "energy-trend",
    "template": "chart",
    "title": "Energy",
    "subtitle": "Last 10 days",
    "value": "18.4",
    "unit": "kWh",
    "status": "good",
    "icon": "chart.bar.xaxis",
    "chart": {
      "points": [22.1, 19.8, 24.3, 20.6, 17.2, 15.9, 18.7, 21.4, 19.1, 18.4],
      "min": 0,
      "max": 30,
      "reference": 20,
      "referenceMetadata": {"label":"Daily target","semantic":{"role":"target"}},
      "style": "bar"
    }
  }'
echo
