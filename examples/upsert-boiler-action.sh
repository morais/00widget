#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "boiler",
    "template": "action",
    "title": "Boiler",
    "subtitle": "Manual mode available",
    "value": "Ready",
    "status": "good",
    "icon": "flame",
    "actions": [
      { "id": "boiler-boost-1h", "label": "Boost 1h", "role": "normal", "confirm": false }
    ]
  }'
echo
