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
# `replacePrefix` makes the snapshot the whole truth for one id namespace:
# anything under `svc-` that this call does not contain is deleted. Without it
# a producer can only ever add, so a service that goes away leaves a dead card
# on the operator's Home Screen that only they can remove.
curl -sS -X POST "$BASE_URL/v1/cards/upsert-batch" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "replacePrefix": "svc-",
    "cards": [
      {
        "id": "svc-api",
        "template": "summary",
        "title": "API",
        "subtitle": "p99 142 ms",
        "value": "Healthy",
        "status": "good",
        "icon": "bolt.horizontal"
      },
      {
        "id": "svc-queue",
        "template": "summary",
        "title": "Queue",
        "subtitle": "oldest job 40 s",
        "value": "12",
        "unit": "jobs",
        "status": "running",
        "icon": "tray.full"
      },
      {
        "id": "svc-database",
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
