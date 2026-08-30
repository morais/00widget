#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# Multiple non-negative series become stacked or grouped vertical bars. The
# server derives legacy `points` totals, so older clients still draw one honest
# bar per day even though they do not know series, labels, or legends.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "energy-sources",
    "template": "chart",
    "title": "Energy",
    "subtitle": "Solar + grid · last 7 days",
    "value": "18.4",
    "unit": "kWh",
    "status": "good",
    "icon": "chart.bar.xaxis",
    "chart": {
      "style": "bar",
      "stacking": "stacked",
      "semantic": {"role":"actual"},
      "labels": ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],
      "min": 0,
      "max": 30,
      "reference": 20,
      "series": [
        {"id":"solar","label":"Solar","points":[12,14,9,16,13,17,11],"semantic":{"flow":"inbound","signal":"favorable"}},
        {"id":"grid","label":"Grid","points":[8,6,11,5,7,4,9],"semantic":{"flow":"inbound","signal":"neutral"}}
      ]
    }
  }'
echo
