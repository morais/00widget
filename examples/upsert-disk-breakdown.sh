#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# `breakdown` splits one bar by each item's `amount`. Shares are computed from
# their sum — never send percentages — and `value` labels the segment.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "disk-usage",
    "template": "breakdown",
    "title": "Disk",
    "subtitle": "912 GB used of 1 TB",
    "value": "89",
    "unit": "%",
    "status": "warning",
    "icon": "internaldrive",
    "items": [
      {"id": "media", "title": "Media", "value": "512 GB", "amount": 512},
      {"id": "backups", "title": "Backups", "value": "280 GB", "amount": 280},
      {"id": "system", "title": "System", "value": "120 GB", "amount": 120},
      {"id": "free", "title": "Free", "value": "112 GB", "amount": 112, "semantic":{"role":"remainder"}}
    ]
  }'
echo
