# Widget Template Cleanup

Temporary tracking file. Delete this file after deployed devices and external integrations are confirmed to be on the simplified contract.

## Goal

Reduce the public mental model to:

- Home Screen widgets: `00Widget Card` and `00Widget Grid`
- Card templates: `summary`, `progress`, `list`, `action`
- Live Activity category: `kind`, used only as a default icon/category hint

Avoid exposing separate Metric, Status, Progress, and List widget choices in the iOS widget gallery.

## Remaining External Checks

Use `docs/llms.md` as the integration prompt for other projects. It now documents only `summary`, `progress`, `list`, and `action`.

Before deleting this file, verify known publishers no longer send:

- `"template": "metric"`
- `"template": "status"`
- `"template": "timer"`

The server now rejects those templates on new card upserts. This check is about finding any external project that still needs its publisher code updated.

## Deployed Device Cleanup

The iOS widget gallery now exposes only the single-card widget and grid widget. Existing installed widgets using the removed WidgetKit kinds may need to be removed and re-added by the user:

- `ZeroZeroWidgetMetricWidget`
- `ZeroZeroWidgetStatusWidget`
- `ZeroZeroWidgetProgressWidget`
- `ZeroZeroWidgetListWidget`

Once there are no active deployed installs worth preserving, old `widget_tokens` rows for those kinds can be deleted from production D1.

## Delete This File When

- External publishers use only `summary`, `progress`, `list`, and `action`.
- Users have recreated any widgets that used the removed WidgetKit kinds.
- Production D1 no longer has useful `widget_tokens` rows for the removed kinds.
