#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# `producer` is who published the card. An operator's dashboard fills up with
# cards from several agents, and a title like "Deploys" does not say which one
# is claiming it. Send your own name — the agent doing the publishing — not the
# vendor whose data you relay.
#
# It is drawn on its own line under the title in the app and on large and
# extra-large widgets. Small and medium widgets, Lock Screen accessories, and
# grid cells drop it, so never put anything the card needs in here.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "deploy-pipeline",
    "template": "summary",
    "title": "Deploys",
    "subtitle": "main · all checks green",
    "value": "12",
    "unit": "today",
    "status": "good",
    "icon": "shippingbox.fill",
    "producer": { "label": "Release Agent", "icon": "sparkles" }
  }'
echo
