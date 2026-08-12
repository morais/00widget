#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

curl -sS -X POST "$BASE_URL/v1/live-activities/start" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "externalActivityId": "solar-surplus-1",
    "kind": "appliance",
    "title": "Solar surplus",
    "state": "running",
    "icon": "sun.max.fill",
    "items": [
      {
        "id": "boiler",
        "title": "Water",
        "icon": "flame.fill",
        "value": "67",
        "unit": "°C",
        "subtitle": "Heating to 78°C",
        "progress": 0.86,
        "status": "running"
      },
      {
        "id": "cooling",
        "title": "Rooms",
        "icon": "snowflake",
        "value": "3",
        "unit": "rooms",
        "subtitle": "Office, Master Bedroom, Julia’s Bedroom",
        "status": "running"
      }
    ]
  }'
echo
