#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# Floating bars show each day's forecast low/high, with the expected daytime
# reading marked inside. rangeValueLabel tells new clients exactly what that
# marker means. The server also stores the marker (or midpoint) as a
# legacy point, so older clients fall back to a useful temperature line.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "weather-range",
    "template": "chart",
    "title": "Forecast",
    "subtitle": "Daily low–high · next 7 days",
    "value": "18",
    "unit": "°C",
    "status": "good",
    "icon": "thermometer.variable",
    "chart": {
      "semantic": {"role":"forecast"},
      "labels": ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],
      "min": 0,
      "max": 30,
      "rangeValueLabel": "Expected daytime",
      "ranges": [
        {"low":12,"high":21,"value":18},
        {"low":10,"high":19,"value":16},
        {"low":13,"high":24,"value":20},
        {"low":14,"high":25,"value":21},
        {"low":11,"high":20,"value":17},
        {"low":9,"high":18,"value":15},
        {"low":12,"high":22,"value":18}
      ]
    }
  }'
echo
