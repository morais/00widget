# 00Widget — Examples

Thin `curl` scripts demonstrating how any agent, automation, or web app can publish state to 00Widget.

## Setup

```
install -m 600 env.example.sh env.sh
# edit env.sh to point at your Worker and set your API key
chmod +x *.sh
```

`env.sh` is gitignored and created with owner-only permissions — it holds your real `BASE_URL` and `API_KEY` and should never be committed.

## Scripts

### Dashboard cards (`/v1/cards/upsert`)

- `upsert-solar.sh` — a `summary` card for solar export.
- `upsert-school-balances.sh` — a `list` card with sub-items, ranked by their `amount`.
- `upsert-boiler-action.sh` — an `action` card with a widget button.
- `upsert-energy-chart.sh` — a `chart` card plotting a 10-point series as a sparkline, with a dashed `reference` target.
- `upsert-grid-delta.sh` — a `chart` card in `delta` style: signed bars around a zero rule.
- `upsert-ci-history.sh` — a `history` card drawing the last 10 CI runs as status pips.
- `upsert-disk-breakdown.sh` — a `breakdown` card splitting one bar by item `amount`.

Each call:
1. Stores the latest state on the backend.
2. Makes a budget-aware WidgetKit reload decision for devices whose configured widgets can display that card.

If one producer run emits multiple related cards, use `/v1/cards/upsert-batch` with `{ "cards": [...] }`. The Worker stores the batch efficiently and makes one reload decision instead of one per card.

### Live Activities (`/v1/live-activities/*`)

- `start-washer.sh` — starts an activity remotely through ActivityKit push-to-start.
- `update-washer-finished.sh` — pushes an update + alert through APNs.
- `start-car-charge.sh` / `update-car-charge.sh` — same shape for a car charging example.
- `start-solar-surplus.sh` — a composite activity with independently rendered sub-items.
- `update-queue-chart.sh` — an activity update carrying a `chart`, drawn as a sparkline on the Lock Screen.

These also illustrate `relevanceScore`: the Smart Stack on iPhone Lock Screen and Apple Watch ranks Live Activities by it (higher wins). Send a low score for "started, plenty of time", ramp it up as urgency grows, and a high score on the finishing alert so it bubbles to the top of the wrist.

Push-to-start flow:
1. Your agent calls `POST /v1/live-activities/start` with a fresh `externalActivityId`.
2. The Worker sends a push-to-start event to every registered device.
3. iOS observes the new activity and registers its per-activity push token (`POST /v1/live-activities/register`).
4. Your agent calls `POST /v1/live-activities/update` or `/end`, and the Worker fans the APNs event out to every registered device.

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
        "template": "summary",
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
    template: "summary",
    title: "Solar",
    value: "3.2",
    unit: "kW",
    status: "good",
  }),
});
```

See `server/README.md` for the complete endpoint and schema list.
