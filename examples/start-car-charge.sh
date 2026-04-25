#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

curl -sS -X POST "$BASE_URL/v1/live-activities/start" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "externalActivityId": "car-charge-1",
    "kind": "charging",
    "title": "Car",
    "state": "charging",
    "subtitle": "Charging at 7.4 kW",
    "value": "42",
    "unit": "%",
    "progress": 0.42,
    "staleAt": "2026-04-24T20:00:00Z"
  }'
echo
