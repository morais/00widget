#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# Category signals describe the producer's interpretation of each period, not
# a literal color. The server derives legacy labels, while current clients add
# renderer-owned tone and non-color symbols for favorable and costly periods.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "tariff-periods",
    "template": "chart",
    "title": "Electricity tariff",
    "subtitle": "Today · consumer perspective",
    "value": "€0.18",
    "unit": "/kWh",
    "status": "good",
    "icon": "clock.badge.exclamationmark",
    "chart": {
      "style": "bar",
      "min": 0,
      "max": 0.5,
      "points": [0.12,0.12,0.18,0.24,0.42,0.42,0.24,0.16],
      "categories": [
        {"id":"00","label":"00","signal":"favorable"},
        {"id":"03","label":"03","signal":"favorable"},
        {"id":"06","label":"06","signal":"neutral"},
        {"id":"09","label":"09","signal":"caution"},
        {"id":"12","label":"12","signal":"unfavorable"},
        {"id":"15","label":"15","signal":"unfavorable"},
        {"id":"18","label":"18","signal":"caution"},
        {"id":"21","label":"21","signal":"favorable"}
      ]
    }
  }'
echo
