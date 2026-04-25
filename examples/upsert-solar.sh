#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "solar-home",
    "template": "metric",
    "title": "Solar",
    "subtitle": "Exporting 0.8 kW",
    "value": "3.2",
    "unit": "kW",
    "status": "good",
    "icon": "sun.max"
  }'
echo
