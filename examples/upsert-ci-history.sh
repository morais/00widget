#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# `history` draws one pip per item, oldest first, colored by the item's status.
# The card's own status summarizes the window.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "ci-history",
    "template": "history",
    "title": "CI",
    "subtitle": "Last 10 runs on main",
    "value": "9/10",
    "status": "warning",
    "icon": "arrow.triangle.2.circlepath",
    "items": [
      {"id": "473", "title": "#473", "value": "3m 51s", "status": "good"},
      {"id": "474", "title": "#474", "value": "4m 02s", "status": "good"},
      {"id": "475", "title": "#475", "value": "3m 12s", "status": "good"},
      {"id": "476", "title": "#476", "value": "5m 18s", "status": "good"},
      {"id": "477", "title": "#477", "value": "1m 04s", "status": "critical"},
      {"id": "478", "title": "#478", "value": "4m 41s", "status": "good"},
      {"id": "479", "title": "#479", "value": "3m 55s", "status": "good"},
      {"id": "480", "title": "#480", "value": "4m 22s", "status": "good"},
      {"id": "481", "title": "#481", "value": "2m 48s", "status": "good"},
      {"id": "482", "title": "#482", "value": "4m 12s", "status": "good"}
    ]
  }'
echo
