#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# One producer snapshot, one call. Batching is not just fewer requests: the
# Worker makes a single WidgetKit reload decision for the whole snapshot, where
# a loop over /v1/cards/upsert spends the account's reload budget once per card
# and can leave the widgets showing a half-updated picture in between.
#
# Card ids must be unique within the batch. Everything else about a card is
# identical to the single-card endpoint.
curl -sS -X POST "$BASE_URL/v1/cards/upsert-batch" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "cards": [
      {
        "id": "api-status",
        "template": "summary",
        "title": "API",
        "subtitle": "p99 142 ms",
        "value": "Healthy",
        "status": "good",
        "icon": "bolt.horizontal"
      },
      {
        "id": "queue-depth",
        "template": "summary",
        "title": "Queue",
        "subtitle": "oldest job 40 s",
        "value": "12",
        "unit": "jobs",
        "status": "running",
        "icon": "tray.full"
      },
      {
        "id": "database-status",
        "template": "summary",
        "title": "Database",
        "subtitle": "replica lag 0.3 s",
        "value": "Healthy",
        "status": "good",
        "icon": "cylinder.split.1x2"
      }
    ]
  }'
echo
