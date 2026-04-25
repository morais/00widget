#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# Queue a pending Live Activity. The iOS app discovers it via
# GET /v1/live-activities/pending and starts it locally.
curl -sS -X POST "$BASE_URL/v1/live-activities/start" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "externalActivityId": "washer-2026-04-24",
    "kind": "appliance",
    "title": "Washing machine",
    "state": "running",
    "subtitle": "Cycle running",
    "progress": 0.2,
    "staleAt": "2026-04-24T18:00:00Z"
  }'
echo
