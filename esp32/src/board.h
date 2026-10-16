#pragma once

// Everything specific to one piece of hardware lives here: the display driver,
// its pins, and which GPIOs the two buttons are on. Porting to another board
// means adding a block like this one and an env in platformio.ini; nothing
// else in the firmware names a pin or a panel.

#define LGFX_USE_V1
#include <LovyanGFX.hpp>

#if defined(BOARD_LILYGO_T_DISPLAY_S3)

// LilyGO T-Display S3: ST7789 170x320 on an 8-bit i8080 bus. GPIO15 powers the
// panel and must be high when running from the battery connector; on USB it is
// harmless either way.
#define BOARD_PIN_POWER_ON 15
#define BOARD_PIN_BUTTON_NEXT 0     // labelled BOOT
#define BOARD_PIN_BUTTON_ACTION 14  // labelled KEY

class Display : public lgfx::LGFX_Device {
  lgfx::Panel_ST7789 panel_;
  lgfx::Bus_Parallel8 bus_;
  lgfx::Light_PWM light_;

 public:
  Display() {
    {
      auto cfg = bus_.config();
      cfg.freq_write = 20000000;
      cfg.pin_wr = 8;
      cfg.pin_rd = 9;
      cfg.pin_rs = 7;
      cfg.pin_d0 = 39;
      cfg.pin_d1 = 40;
      cfg.pin_d2 = 41;
      cfg.pin_d3 = 42;
      cfg.pin_d4 = 45;
      cfg.pin_d5 = 46;
      cfg.pin_d6 = 47;
      cfg.pin_d7 = 48;
      bus_.config(cfg);
      panel_.setBus(&bus_);
    }
    {
      auto cfg = panel_.config();
      cfg.pin_cs = 6;
      cfg.pin_rst = 5;
      cfg.pin_busy = -1;
      cfg.panel_width = 170;
      cfg.panel_height = 320;
      cfg.offset_x = 35;
      cfg.offset_y = 0;
      cfg.offset_rotation = 0;
      cfg.readable = false;
      cfg.invert = true;
      cfg.rgb_order = false;
      cfg.dlen_16bit = false;
      cfg.bus_shared = false;
      panel_.config(cfg);
    }
    {
      auto cfg = light_.config();
      cfg.pin_bl = 38;
      cfg.invert = false;
      cfg.freq = 22000;
      cfg.pwm_channel = 7;
      light_.config(cfg);
      panel_.setLight(&light_);
    }
    setPanel(&panel_);
  }
};

// Landscape, with the buttons on the right.
#define BOARD_ROTATION 1

#else
#error "No board selected. Add a -DBOARD_... flag in platformio.ini (see src/board.h)."
#endif
