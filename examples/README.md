# 00Widget — Examples

Thin `curl` scripts demonstrating how any agent, automation, or web app can publish state to 00Widget.

## Setup

```
cp env.example.sh env.sh
# edit env.sh to point at your Worker and set your API key
chmod +x *.sh
```

`env.sh` is gitignored — it holds your real `BASE_URL` and `API_KEY` and should never be committed.

## Scripts

### Dashboard cards (`/v1/cards/upsert`)

- `upsert-solar.sh` — a `metric` card for solar export.
- `upsert-school-balances.sh` — a `list` card with sub-items.
- `upsert-boiler-action.sh` — an `action` card with a widget button.

Each call:
1. Stores the latest state on the backend.
2. Fan-outs a WidgetKit reload push to every registered widget token (once the iOS app has registered any).

### Live Activities (`/v1/live-activities/*`)

- `start-washer.sh` — queues a pending activity for the app to start.
- `update-washer-finished.sh` — pushes an update + alert through APNs.
- `start-tesla-charge.sh` / `update-tesla-charge.sh` — same shape for a Tesla charging example.

Pending → live flow:
1. Your agent calls `POST /v1/live-activities/start` with a fresh `externalActivityId`.
2. The iOS app periodically calls `GET /v1/live-activities/pending` and starts the activity locally.
3. iOS observes the per-activity push token and registers it (`POST /v1/live-activities/register`).
4. Your agent can then call `POST /v1/live-activities/update` or `/end`, which the Worker translates into an APNs push.

### Actions (`/v1/actions/:id/run`)

- `run-boiler-boost-action.sh` — invokes an action by id.

In v1 the Worker just logs and succeeds. Wire actions to webhooks in `server/src/actions.ts` when you're ready.

## Publishing from your own agent

The API is HTTP+JSON. Any runtime that can make a POST works:

```bash
# shell
curl -X POST $BASE_URL/v1/cards/upsert \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d @my-card.json
```

```python
# python
import requests
requests.post(
    f"{BASE_URL}/v1/cards/upsert",
    headers={"Authorization": f"Bearer {API_KEY}"},
    json={
        "id": "solar-home",
        "template": "metric",
        "title": "Solar",
        "value": "3.2",
        "unit": "kW",
        "status": "good",
    },
)
```

```javascript
// node / cloudflare / browser
await fetch(`${BASE_URL}/v1/cards/upsert`, {
  method: "POST",
  headers: {
    "Authorization": `Bearer ${API_KEY}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    id: "solar-home",
    template: "metric",
    title: "Solar",
    value: "3.2",
    unit: "kW",
    status: "good",
  }),
});
```

See `server/README.md` for the complete endpoint and schema list.
