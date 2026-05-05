DELETE FROM widget_tokens
WHERE widget_kind IN (
  'ZeroZeroWidgetMetricWidget',
  'ZeroZeroWidgetStatusWidget',
  'ZeroZeroWidgetProgressWidget',
  'ZeroZeroWidgetListWidget',
  'ZeroZeroWidgetMetricsGridWidget'
);
