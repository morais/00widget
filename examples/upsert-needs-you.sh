#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# "Needs you" is how an agent says it has run out of things it can decide on
# its own. There is no field for it — it is DERIVED, and a card earns the badge
# only by publishing both halves of the claim:
#
#   1. an attention `status` — warning, critical, offline, paused, or unknown
#   2. at least one entry in `actions`
#
# Send the status without an action and the card keeps its ordinary status
# badge, which is the honest outcome: a warning nobody can act on from the card
# is an observation, not a hand-off. Send an action without an attention status
# and it is just a healthy card with a button.
#
# Drop either line below and the badge disappears.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "release-approval",
    "template": "summary",
    "title": "Launch",
    "subtitle": "Customer announcement waiting",
    "value": "4/5",
    "status": "warning",
    "icon": "shippingbox.fill",
    "producer": { "label": "Release Agent", "icon": "sparkles" },
    "progress": 0.8,
    "actions": [
      { "id": "approve-launch", "label": "Approve" }
    ]
  }'
echo
