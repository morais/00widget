#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

curl -sS -X POST "$BASE_URL/v1/live-activities/update" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "externalActivityId": "tesla-charge-1",
    "state": "charging",
    "subtitle": "Charging at 7.4 kW",
    "value": "78",
    "unit": "%",
    "progress": 0.78,
    "relevanceScore": 78
  }'
echo
