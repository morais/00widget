#pragma once

#include <Arduino.h>
#include <time.h>
#include <vector>

// The subset of the server's DashboardCard (server/src/types.ts) this client
// draws. Fields it has no surface for are dropped while parsing.

struct CardItem {
  String title;
  String subtitle;
  String value;
  String unit;
  String status;
  float amount = NAN;
};

// One layer of a multi-series bar chart. `points` of every series line up
// with each other; the semantic hints decide colour, as on iOS.
struct ChartSeries {
  String label;
  std::vector<float> points;
  String role;
  String flow;
  String signal;
};

struct CardAction {
  String id;
  String label;
};

struct Card {
  String id;
  String templ;
  String title;
  String subtitle;
  String value;
  String unit;
  String status = "unknown";

  String comparisonValue;
  String comparisonLabel;
  String comparisonSignal;

  float progress = NAN;
  time_t updatedAt = 0;
  time_t staleAfter = 0;
  time_t deadline = 0;

  std::vector<CardItem> items;

  std::vector<float> points;
  String chartStyle;
  float chartMin = NAN;
  float chartMax = NAN;
  float chartReference = NAN;
  std::vector<ChartSeries> series;
  bool grouped = false;  // side by side rather than stacked

  String briefingText;

  // Only actions a widget may run: not destructive, no confirmation. The rest
  // need a person to read a confirmation, which this screen cannot ask for.
  std::vector<CardAction> actions;
  bool hadUnsafeActions = false;

  // Configured id that the server did not return.
  bool missing = false;
};
