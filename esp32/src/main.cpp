// 00Widget display client: shows a fixed list of dashboard cards, one per
// screen. One button moves between cards; the other runs the card's action.
//
// Networking runs in its own task so a slow TLS handshake never makes the
// buttons feel dead; the UI loop only ever reads a snapshot under a mutex.

#include <Arduino.h>
#include <ESPmDNS.h>
#include <WebServer.h>
#include <WiFi.h>
#include <esp_sntp.h>
#include <mbedtls/base64.h>

#include "api.h"
#include "board.h"
#include "config.h"
#include "render.h"

namespace {

Display display;
LGFX_Sprite canvas(&display);

// --- Shared state, guarded by `lock` -----------------------------------------

SemaphoreHandle_t lock;
std::vector<Card> cards;
bool haveFetched = false;
bool canRunActions = false;
String fetchError;
// Consecutive failed polls. On a marginal Wi-Fi link single requests fail
// routinely and the next one succeeds, so one failure is not "offline".
int failedPolls = 0;
constexpr int kOfflineAfterFailures = 3;
int fetchStatus = 0;
time_t lastSuccess = 0;
volatile bool refreshRequested = true;
// False while the quiet period has the screen off; the network task does not
// poll then, so nothing is fetched that nobody will see.
volatile bool screenOn = true;

struct PendingAction {
  String actionId;
  String cardId;
  String label;
};
PendingAction pendingAction;
bool actionQueued = false;
String actionResult;  // toast text, set by the network task
bool actionOk = false;

// --- UI-only state -------------------------------------------------------------

size_t current = 0;
size_t selectedAction = 0;
String currentCardId;  // keeps the screen on the same card across refreshes
uint32_t lastInteraction = 0;
uint32_t lastAutoRotate = 0;
String toast;
uint32_t toastColor = 0;
uint32_t toastUntil = 0;
uint32_t wokenAt = 0;  // when a button last woke the screen in the quiet period

// What the local control endpoint last asked for. It outranks the quiet
// period until another command changes it; `auto` hands back to the schedule.
enum class Remote { Auto, Sleep, Wake };
volatile Remote remote = Remote::Auto;

time_t clockNow() {
  time_t t = time(nullptr);
  return t > 1700000000 ? t : 0;  // before NTP the RTC counts from 1970
}

// Minutes past midnight for "HH:MM", or -1 if it isn't one.
int minuteOfDay(const char* hhmm) {
  int h, m;
  if (sscanf(hhmm, "%d:%d", &h, &m) != 2 || h < 0 || h > 23 || m < 0 || m > 59) return -1;
  return h * 60 + m;
}

// Without a clock there is no telling whether it is night, and a screen that
// stays dark because NTP hasn't answered looks broken, so that reads as no.
bool inQuietPeriod() {
#if defined(ZW_QUIET_START) && defined(ZW_QUIET_END)
  static const int start = minuteOfDay(ZW_QUIET_START), end = minuteOfDay(ZW_QUIET_END);
  time_t t = clockNow();
  if (!t || start < 0 || end < 0 || start == end) return false;
  struct tm local;
  localtime_r(&t, &local);
  int m = local.tm_hour * 60 + local.tm_min;
  return start < end ? (m >= start && m < end) : (m >= start || m < end);  // may span midnight
#else
  return false;
#endif
}

#ifndef ZW_QUIET_WAKE_SECONDS
#define ZW_QUIET_WAKE_SECONDS 30
#endif

// Off when told to sleep, or in the quiet period unless told to wake; a
// button press still buys ZW_QUIET_WAKE_SECONDS either way.
bool screenScheduledOff() {
  Remote r = remote;
  return r == Remote::Sleep || (r == Remote::Auto && inQuietPeriod());
}

bool screenShouldBeOn() {
  return !screenScheduledOff() || (wokenAt && millis() - wokenAt < ZW_QUIET_WAKE_SECONDS * 1000UL);
}

// --- Local control endpoint -----------------------------------------------------
//
// Plain HTTP on the LAN, so another device (a presence sensor, Home Assistant)
// can put the screen to sleep and wake it. Off unless ZW_LOCAL_TOKEN is set.

#ifndef ZW_LOCAL_PORT
#define ZW_LOCAL_PORT 80
#endif
#ifndef ZW_HOSTNAME
#define ZW_HOSTNAME "00widget"
#endif

#ifdef ZW_LOCAL_TOKEN
WebServer server(ZW_LOCAL_PORT);

// Same work whatever the first wrong byte, so timing doesn't leak the token.
bool tokenMatches(const String& given) {
  const char* want = ZW_LOCAL_TOKEN;
  size_t n = strlen(want);
  uint8_t diff = given.length() != n;
  for (size_t i = 0; i < n; i++) diff |= (uint8_t)want[i] ^ (uint8_t)(i < given.length() ? given[i] : 0);
  return diff == 0;
}

bool authorized() {
  String auth = server.header("Authorization");
  if (auth.startsWith("Bearer ")) return tokenMatches(auth.substring(7));
  return server.hasArg("token") && tokenMatches(server.arg("token"));
}

const char* remoteName() {
  switch (remote) {
    case Remote::Sleep: return "sleep";
    case Remote::Wake: return "wake";
    default: return "auto";
  }
}

void sendState() {
  // What the screen is about to be, not what it was: the loop applies a
  // command just after this reply goes out.
  bool on = screenShouldBeOn();
  String body = String("{\"screen\":\"") + (on ? "on" : "off") + "\",\"mode\":\"" + remoteName() +
                "\",\"quietPeriod\":" + (inQuietPeriod() ? "true" : "false") + "}\n";
  server.send(200, "application/json", body);
}

void command(Remote mode) {
  if (!authorized()) {
    server.send(401, "application/json", "{\"error\":\"bad token\"}\n");
    return;
  }
  remote = mode;
  wokenAt = 0;  // a command decides outright, not a button's grace window
  Serial.printf("[zw] local: %s\n", remoteName());
  sendState();
}

void startLocalServer() {
  const char* headers[] = {"Authorization"};
  server.collectHeaders(headers, 1);
  server.on("/sleep", HTTP_POST, [] { command(Remote::Sleep); });
  server.on("/wake", HTTP_POST, [] { command(Remote::Wake); });
  server.on("/auto", HTTP_POST, [] { command(Remote::Auto); });
  server.on("/state", HTTP_GET, [] {
    if (!authorized()) return server.send(401, "application/json", "{\"error\":\"bad token\"}\n");
    sendState();
  });
  server.onNotFound([] { server.send(404, "text/plain", "not found\n"); });
  server.begin();
}

void serviceLocalServer() {
  static bool announced = false;
  if (!announced && WiFi.status() == WL_CONNECTED) {
    announced = true;
    if (MDNS.begin(ZW_HOSTNAME)) MDNS.addService("http", "tcp", ZW_LOCAL_PORT);
    Serial.printf("[zw] local control on http://%s:%d (%s.local)\n",
                  WiFi.localIP().toString().c_str(), ZW_LOCAL_PORT, ZW_HOSTNAME);
  }
  server.handleClient();
}
#else
void startLocalServer() {}
void serviceLocalServer() {}
#endif

bool configured() { return strncmp(ZW_API_TOKEN, "zw_...", 6) != 0 && strlen(ZW_API_TOKEN) > 8; }

// --- Buttons -------------------------------------------------------------------

struct Button {
  uint8_t pin;
  bool down = false;
  bool longFired = false;
  uint32_t since = 0;

  explicit Button(uint8_t p) : pin(p) {}

  enum Event { None, Short, Long };

  Event poll() {
    bool pressed = digitalRead(pin) == LOW;
    uint32_t now = millis();
    if (pressed != down) {
      if (now - since < 30) return None;  // debounce
      down = pressed;
      since = now;
      if (!pressed && !longFired) return Short;
      if (pressed) longFired = false;
      return None;
    }
    if (down && !longFired && now - since > 700) {
      longFired = true;
      return Long;
    }
    return None;
  }
};

#ifdef ZW_SWAP_BUTTONS
Button nextButton{BOARD_PIN_BUTTON_ACTION};
Button actionButton{BOARD_PIN_BUTTON_NEXT};
#else
Button nextButton{BOARD_PIN_BUTTON_NEXT};
Button actionButton{BOARD_PIN_BUTTON_ACTION};
#endif

void showToast(const String& text, uint32_t rgb, uint32_t ms = 2500) {
  toast = text;
  toastColor = rgb;
  toastUntil = millis() + ms;
}

// --- Network task ----------------------------------------------------------------

void networkTask(void*) {
  uint32_t lastPoll = 0;
  bool scopesKnown = false;
  for (;;) {
    if (WiFi.status() != WL_CONNECTED) {
      vTaskDelay(pdMS_TO_TICKS(500));
      continue;
    }

    bool doAction = false;
    PendingAction action;
    xSemaphoreTake(lock, portMAX_DELAY);
    if (actionQueued) {
      action = pendingAction;
      actionQueued = false;
      doAction = true;
    }
    xSemaphoreGive(lock);

    if (doAction) {
      FetchResult r = runAction(action.actionId, action.cardId);
      xSemaphoreTake(lock, portMAX_DELAY);
      actionOk = r.ok();
      actionResult = r.ok() ? "Sent: " + action.label : "Failed: " + r.error;
      xSemaphoreGive(lock);
      // Producers usually republish the card in response; look sooner.
      lastPoll = millis() - (ZW_POLL_SECONDS * 1000UL) + 3000;
    }

    if (!screenOn) {
      vTaskDelay(pdMS_TO_TICKS(250));
      continue;
    }
    bool due = refreshRequested || millis() - lastPoll > ZW_POLL_SECONDS * 1000UL;
    if (!due) {
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    bool forced = refreshRequested;
    refreshRequested = false;
    lastPoll = millis();

    if (!scopesKnown || forced) {
      bool can = false;
      FetchResult r = fetchScopes(can);
      Serial.printf("[zw] status: %d %s actions:run=%d\n", r.httpStatus, r.error.c_str(), can);
      if (r.ok()) {
        scopesKnown = true;
        xSemaphoreTake(lock, portMAX_DELAY);
        canRunActions = can;
        xSemaphoreGive(lock);
      }
    }

    std::vector<Card> fresh;
    FetchResult r = fetchCards(fresh);
    Serial.printf("[zw] cards: %d %s (%u shown, rssi %d, heap %u, min %u, block %u)\n",
                  r.httpStatus, r.error.c_str(), (unsigned)fresh.size(), WiFi.RSSI(),
                  ESP.getFreeHeap(), ESP.getMinFreeHeap(),
                  heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
    xSemaphoreTake(lock, portMAX_DELAY);
    fetchStatus = r.httpStatus;
    if (r.ok()) {
      cards = std::move(fresh);
      fetchError = "";
      failedPolls = 0;
      lastSuccess = clockNow();
      haveFetched = true;
    } else {
      fetchError = r.error;
      failedPolls++;
      // A failed poll retries in ten seconds rather than a whole interval.
      lastPoll = millis() - ZW_POLL_SECONDS * 1000UL + 10000;
    }
    xSemaphoreGive(lock);
  }
}

// --- Rendering -----------------------------------------------------------------

void render() {
  ScreenState s;
  s.now = clockNow();
  if (millis() < toastUntil) {
    s.toast = toast;
    s.toastColor = toastColor;
  }

  if (!configured()) {
    renderMessage(canvas, "Not configured",
                  "Copy include/config.h.sample to include/config.h, add your Wi-Fi and token, "
                  "and flash again.",
                  0xFF9F0A, s);
    canvas.pushSprite(0, 0);
    return;
  }
  if (WiFi.status() != WL_CONNECTED && !haveFetched) {
    renderMessage(canvas, "Connecting...", String("Wi-Fi: ") + ZW_WIFI_SSID, 0x0A84FF, s);
    canvas.pushSprite(0, 0);
    return;
  }

  xSemaphoreTake(lock, portMAX_DELAY);
  if (!haveFetched) {
    if (fetchError.length()) {
      String body = fetchStatus == 401 ? "Check ZW_API_TOKEN in config.h. It may have been revoked."
                                       : fetchError + " - retrying.";
      renderMessage(canvas, fetchStatus == 401 ? "Token rejected" : "Can't reach 00Widget", body,
                    0xFF453A, s);
    } else {
      renderMessage(canvas, "Loading cards...", ZW_BASE_URL, 0x0A84FF, s);
    }
  } else if (cards.empty()) {
    renderMessage(canvas, "No cards yet",
                  "Publish a card from an agent and it will appear here.", 0x8E8E93, s);
  } else {
    // Follow the card, not the index, so a refresh that reorders or removes
    // cards doesn't move the screen out from under someone reading it.
    for (size_t i = 0; i < cards.size(); i++) {
      if (cards[i].id == currentCardId) current = i;
    }
    if (current >= cards.size()) current = 0;
    currentCardId = cards[current].id;

    s.index = current;
    s.count = cards.size();
    s.canRunActions = canRunActions;
    s.selectedAction = selectedAction;
    if (failedPolls >= kOfflineAfterFailures) s.fetchError = fetchError;
    s.lastSuccess = lastSuccess;
    renderCard(canvas, cards[current], s);
  }
  xSemaphoreGive(lock);
  canvas.pushSprite(0, 0);
}

void move(int delta) {
  xSemaphoreTake(lock, portMAX_DELAY);
  size_t n = cards.size();
  if (n) {
    current = (current + n + delta) % n;
    currentCardId = cards[current].id;
  }
  xSemaphoreGive(lock);
  selectedAction = 0;
  lastAutoRotate = millis();
}

void cycleAction() {
  xSemaphoreTake(lock, portMAX_DELAY);
  size_t n = current < cards.size() ? cards[current].actions.size() : 0;
  bool hadUnsafe = current < cards.size() && cards[current].hadUnsafeActions;
  bool can = canRunActions;
  xSemaphoreGive(lock);
  if (n == 0) {
    showToast(hadUnsafe ? "Needs confirming in the app" : "No action on this card", 0x9A9AA0);
  } else if (!can) {
    showToast("Token can't run actions", 0x9A9AA0);
  } else if (n > 1) {
    selectedAction = (selectedAction + 1) % n;
  }
}

void triggerAction() {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool queued = false;
  String label;
  if (current < cards.size() && !cards[current].actions.empty() && canRunActions && !actionQueued) {
    const Card& card = cards[current];
    const CardAction& a = card.actions[selectedAction % card.actions.size()];
    pendingAction = {a.id, card.id, a.label};
    actionQueued = true;
    queued = true;
    label = a.label;
  }
  xSemaphoreGive(lock);
  if (queued) {
    showToast("Running " + label + "...", 0x0A84FF, 15000);
  } else {
    cycleAction();  // same explanation as a short press
  }
}

// Writes the frame buffer to serial as base64 RGB565, for tools/screenshot.py.
void dumpScreenshot() {
  const uint8_t* buf = (const uint8_t*)canvas.getBuffer();
  size_t len = canvas.width() * canvas.height() * 2;
  Serial.printf("\nZWSHOT %d %d\n", canvas.width(), canvas.height());
  const size_t chunk = 3 * 256;
  unsigned char out[4 * 256 + 4];
  for (size_t off = 0; off < len; off += chunk) {
    size_t n = min(chunk, len - off), olen = 0;
    mbedtls_base64_encode(out, sizeof out, &olen, buf + off, n);
    Serial.write(out, olen);
  }
  Serial.print("\nZWEND\n");
}

void wake();

void handleSerial() {
  while (Serial.available()) {
    wake();
    switch (Serial.read()) {
      case 'n': move(1); break;
      case 'p': move(-1); break;
      case 'a': cycleAction(); break;
      case 'A': triggerAction(); break;
      case 'r': refreshRequested = true; showToast("Refreshing...", 0x9A9AA0, 1500); break;
      case 's': render(); dumpScreenshot(); break;
    }
    lastInteraction = millis();
  }
}

void setScreen(bool on) {
  if (on == screenOn) return;
  if (on) {
    display.wakeup();
    render();  // draw before the backlight comes up, not after
    display.setBrightness(ZW_BRIGHTNESS);
    // What is on screen is from before the screen went off; replace it now
    // rather than up to a whole poll interval later.
    refreshRequested = true;
  } else {
    display.setBrightness(0);
    display.sleep();
  }
  screenOn = on;
  Serial.printf("[zw] screen %s\n", on ? "on" : "off");
}

// Starts (or extends) the window a button press buys in the quiet period.
void wake() {
  wokenAt = millis();
  if (!screenOn) setScreen(true);
}

}  // namespace

void setup() {
  Serial.begin(115200);
#ifdef BOARD_PIN_POWER_ON
  pinMode(BOARD_PIN_POWER_ON, OUTPUT);
  digitalWrite(BOARD_PIN_POWER_ON, HIGH);
#endif
  pinMode(nextButton.pin, INPUT_PULLUP);
  pinMode(actionButton.pin, INPUT_PULLUP);

  display.init();
  display.setRotation(BOARD_ROTATION);
  display.setBrightness(ZW_BRIGHTNESS);
  canvas.setPsram(true);
  canvas.setColorDepth(16);
  canvas.createSprite(display.width(), display.height());

  lock = xSemaphoreCreateMutex();
  render();
  if (!configured()) return;

  setenv("TZ", ZW_TIMEZONE, 1);
  tzset();
  configTzTime(ZW_TIMEZONE, "pool.ntp.org", "time.google.com");

  WiFi.mode(WIFI_STA);
  WiFi.setHostname(ZW_HOSTNAME);
  WiFi.setAutoReconnect(true);
  // Modem sleep saves nothing worth having on a mains-powered display, and
  // with some routers it drops packets mid-handshake (mbedTLS -76).
  WiFi.setSleep(false);
  WiFi.begin(ZW_WIFI_SSID, ZW_WIFI_PASSWORD);

  startLocalServer();
  xTaskCreatePinnedToCore(networkTask, "zw-net", 16384, nullptr, 1, nullptr, 0);
  lastAutoRotate = millis();
}

void loop() {
  static uint32_t lastRender = 0;
  bool changed = false;

  // In the quiet period the screen is off unless a button woke it recently.
  serviceLocalServer();

  bool quiet = screenScheduledOff();
  bool shouldBeOn = screenShouldBeOn();
  if (!screenOn) {
    // The press that wakes the screen is spent waking it: whoever pressed it
    // in the dark could not see which card a "next" or an action would hit.
    Button::Event a = nextButton.poll(), b = actionButton.poll();
    if (a != Button::None || b != Button::None) {
      wake();
      lastInteraction = millis();
    } else if (shouldBeOn) {
      setScreen(true);
    }
    handleSerial();
    delay(10);
    return;
  }
  if (!shouldBeOn) {
    setScreen(false);
    return;
  }

  switch (nextButton.poll()) {
    case Button::Short: move(1); changed = true; break;
    case Button::Long:
      refreshRequested = true;
      showToast("Refreshing...", 0x9A9AA0, 1500);
      changed = true;
      break;
    default: break;
  }
  switch (actionButton.poll()) {
    case Button::Short: cycleAction(); changed = true; break;
    case Button::Long: triggerAction(); changed = true; break;
    default: break;
  }
  if (changed) {
    lastInteraction = millis();
    if (quiet) wokenAt = millis();  // keep it on while it is being used
  }
  handleSerial();

  // Hand the network task's verdict on an action to the UI.
  xSemaphoreTake(lock, portMAX_DELAY);
  if (actionResult.length()) {
    showToast(actionResult, actionOk ? 0x30D158 : 0xFF453A);
    actionResult = "";
    changed = true;
  }
  xSemaphoreGive(lock);

  // Auto-rotate, but never out from under someone who just pressed a button.
  if (ZW_AUTO_ROTATE_SECONDS > 0 && millis() - lastAutoRotate > ZW_AUTO_ROTATE_SECONDS * 1000UL &&
      millis() - lastInteraction > 60000UL) {
    move(1);
    changed = true;
  }

  // Once a second keeps the clock, ages and countdowns honest.
  if (changed || millis() - lastRender > 1000) {
    render();
    lastRender = millis();
  }
  delay(10);
}
