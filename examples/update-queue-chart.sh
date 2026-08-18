#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# A Live Activity's `chart` is content state, so every update may carry a new
# window — send the whole window each time, oldest first. It is drawn on the
# Lock Screen and in the expanded Dynamic Island when the activity has no item
# rows, and in the app either way.
curl -sS -X POST "$BASE_URL/v1/live-activities/update" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "externalActivityId": "queue-irn-odivelas",
    "state": "waiting",
    "subtitle": "6 senhas à frente",
    "value": "A61",
    "unit": "em atendimento",
    "chart": {
      "points": [22, 21, 19, 17, 16, 14, 11, 9, 7, 6],
      "min": 0,
      "style": "bar"
    }
  }'
echo
