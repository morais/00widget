#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# A briefing is progressive: value and subtitle are the compact conclusion and
# old-client fallback; larger surfaces reveal ordered, self-contained sections.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "release-briefing",
    "template": "briefing",
    "title": "Release",
    "value": "2 blockers",
    "subtitle": "Payments deploy needs attention",
    "status": "warning",
    "icon": "text.document",
    "briefing": {
      "sections": [
        {"id":"cause","label":"Cause","text":"The database migration is waiting for production approval."},
        {"id":"impact","label":"Impact","text":"Checkout is unaffected, but the refund fix has not shipped."},
        {"id":"next","label":"Next","text":"Approve migration 1842, then retry the payments deployment."}
      ]
    }
  }'
echo
