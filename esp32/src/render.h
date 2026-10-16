#pragma once

#include "board.h"
#include "card.h"

struct ScreenState {
  size_t index = 0;
  size_t count = 0;
  time_t now = 0;  // 0 until NTP has set the clock
  bool canRunActions = false;
  size_t selectedAction = 0;
  // Set while the last fetch failed; the cards on screen are from before it.
  String fetchError;
  time_t lastSuccess = 0;
  String toast;
  uint32_t toastColor = 0;  // 0xRRGGBB
};

void renderCard(LGFX_Sprite& g, const Card& card, const ScreenState& s);

// A full-screen notice for states with no card to show: connecting, a
// rejected token, an empty dashboard.
void renderMessage(LGFX_Sprite& g, const String& title, const String& body, uint32_t accent,
                   const ScreenState& s);
