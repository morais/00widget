#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

# A `timeline` card carries one complete fixed observation window. Point
# entries omit endAt; duration entries include it. Lanes are the observed
# subjects, while series are the kinds of events shown in the legend.
curl -sS -X POST "$BASE_URL/v1/cards/upsert" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  --data '{
    "id": "home-activity",
    "template": "timeline",
    "title": "Home activity",
    "subtitle": "Last motion 29 min ago",
    "value": "Likely home",
    "status": "good",
    "icon": "house.fill",
    "timeline": {
      "startAt": "2026-09-15T10:00:00Z",
      "endAt": "2026-09-15T16:00:00Z",
      "lanes": [
        {"id": "override", "label": "Override"},
        {"id": "house", "label": "Whole house"}
      ],
      "series": [
        {"id": "motion", "label": "Motion", "icon": "figure.walk"},
        {"id": "front-door", "label": "Front door", "icon": "door.left.hand.open"},
        {"id": "garage", "label": "Garage", "icon": "door.garage.open"},
        {"id": "quiet", "label": "Quiet", "icon": "moon.zzz.fill"}
      ],
      "entries": [
        {"id": "motion-1", "laneId": "house", "seriesId": "motion", "at": "2026-09-15T10:31:00Z"},
        {"id": "front-1", "laneId": "house", "seriesId": "front-door", "at": "2026-09-15T10:55:00Z"},
        {"id": "garage-1", "laneId": "house", "seriesId": "garage", "at": "2026-09-15T11:08:00Z"},
        {"id": "quiet-1", "laneId": "override", "seriesId": "quiet", "at": "2026-09-15T11:08:00Z", "endAt": "2026-09-15T12:20:00Z", "label": "No movement for 15+ min"}
      ]
    }
  }'
echo
