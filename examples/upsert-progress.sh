#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# `progress` is the fraction, 0.0-1.0, and it draws the bar. `value` stays what
# it is on every other template: a display string already formatted for a
# person. Sending both is how a progress card shows how far along it is *and*
# what that means — "184 of 240" over a bar at 77%.
#
# `deadline` is rendered as a countdown the device ticks locally, so it stays
# right between widget reloads without costing any.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data "$(cat <<JSON
{
  "id": "test-suite",
  "template": "progress",
  "title": "Test suite",
  "subtitle": "integration",
  "value": "184 of 240",
  "progress": 0.767,
  "status": "running",
  "icon": "checklist",
  "deadline": "$(date -u -v+18M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+18 minutes' +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
)"
echo
