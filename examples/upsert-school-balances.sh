#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "school-balances",
    "template": "list",
    "title": "School balances",
    "status": "good",
    "icon": "creditcard",
    "items": [
      { "id": "child-1", "title": "Child 1", "value": "12.40", "unit": "€", "status": "good" },
      { "id": "child-2", "title": "Child 2", "value": "8.10",  "unit": "€", "status": "warning" }
    ]
  }'
echo
