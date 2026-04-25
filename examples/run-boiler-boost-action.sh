#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

curl -sS -X POST "$BASE_URL/v1/actions/boiler-boost-1h/run" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "source": "external",
    "context": { "cardId": "boiler" }
  }'
echo
