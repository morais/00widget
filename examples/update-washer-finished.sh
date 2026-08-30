#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# Updates an already-running Live Activity through APNs. Requires
# the iOS app to have called POST /v1/live-activities/register to store
# the ActivityKit push token for this externalActivityId.
curl -sS -X POST "$BASE_URL/v1/live-activities/update" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "externalActivityId": "washer-2026-04-24",
    "state": "finished",
    "signal": "favorable",
    "title": "Washing machine",
    "subtitle": "Cycle finished",
    "progress": 1.0,
    "relevanceScore": 100,
    "alert": {
      "title": "Washing machine finished",
      "body": "The cycle appears to be complete."
    }
  }'
echo
