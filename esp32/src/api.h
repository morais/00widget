#pragma once

#include <vector>

#include "card.h"

struct FetchResult {
  int httpStatus = 0;  // 0 = never reached the server
  String error;
  bool ok() const { return httpStatus >= 200 && httpStatus < 300 && error.isEmpty(); }
};

// GET /v1/cards, filtered and ordered by the configured ids.
FetchResult fetchCards(std::vector<Card>& out);

// GET /v1/status, to learn whether this token may run actions.
FetchResult fetchScopes(bool& canRunActions);

// POST /v1/actions/<id>/run with the card as context.
FetchResult runAction(const String& actionId, const String& cardId);

time_t parseIsoDate(const char* s);
