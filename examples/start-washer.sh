#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# Start a Live Activity remotely through ActivityKit push-to-start.
curl -sS -X POST "$BASE_URL/v1/live-activities/start" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "externalActivityId": "washer-2026-04-24",
    "kind": "appliance",
    "title": "Washing machine",
    "state": "running",
    "signal": "neutral",
    "subtitle": "Cycle running",
    "progress": 0.2,
    "staleAt": "2026-04-24T18:00:00Z",
    "relevanceScore": 50,
    "alert": {
      "title": "Washing machine",
      "body": "Cycle started"
    }
  }'
echo
