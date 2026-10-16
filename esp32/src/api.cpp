#include "api.h"

#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>

#include "config.h"
#include "roots.h"

namespace {

const char* const kConfiguredIds[] = ZW_CARD_IDS;
// `{}` makes the array above zero-length, which sizeof handles and a template
// helper would not.
constexpr size_t kConfiguredIdCount = sizeof(kConfiguredIds) / sizeof(kConfiguredIds[0]);

constexpr uint32_t kTimeoutMs = 15000;

String urlEncode(const String& s) {
  static const char* hex = "0123456789ABCDEF";
  String out;
  out.reserve(s.length() * 3);
  for (size_t i = 0; i < s.length(); i++) {
    uint8_t c = s[i];
    if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
      out += (char)c;
    } else {
      out += '%';
      out += hex[c >> 4];
      out += hex[c & 15];
    }
  }
  return out;
}

// One request on a fresh TLS connection. A poll a minute does not justify
// keeping a socket open, and a fresh one never has to recover from a server
// that closed it.
template <typename OnBody>
FetchResult request(const char* method, const String& path, const String& body, OnBody onBody) {
  FetchResult result;
  WiFiClientSecure client;
  client.setCACert(kRootCertificates);
  client.setTimeout(kTimeoutMs / 1000);

  HTTPClient http;
  // HTTP/1.0 so the body is never chunked: ArduinoJson then reads it straight
  // off the socket instead of from a buffered copy.
  http.useHTTP10(true);
  http.setTimeout(kTimeoutMs);
  http.setUserAgent("00Widget-ESP32/1.0");
  if (!http.begin(client, String(ZW_BASE_URL) + path)) {
    result.error = "bad URL";
    return result;
  }
  http.addHeader("Authorization", String("Bearer ") + ZW_API_TOKEN);
  http.addHeader("Accept", "application/json");
  if (body.length()) http.addHeader("Content-Type", "application/json");

  int code = http.sendRequest(method, body);
  if (code <= 0) {
    result.error = HTTPClient::errorToString(code);
    http.end();
    return result;
  }
  result.httpStatus = code;
  if (code >= 200 && code < 300) {
    result.error = onBody(http.getStream());
  } else if (code == 401) {
    result.error = "token rejected";
  } else if (code == 403) {
    result.error = "token lacks scope";
  } else if (code == 429) {
    result.error = "rate limited";
  } else {
    result.error = String("HTTP ") + code;
  }
  http.end();
  return result;
}

String str(JsonVariantConst v) {
  const char* s = v.as<const char*>();
  return s ? String(s) : String();
}

float num(JsonVariantConst v) { return v.is<float>() ? v.as<float>() : NAN; }

Card parseCard(JsonObjectConst c) {
  Card card;
  card.id = str(c["id"]);
  card.templ = str(c["template"]);
  card.title = str(c["title"]);
  card.subtitle = str(c["subtitle"]);
  card.value = str(c["value"]);
  card.unit = str(c["unit"]);
  if (c["status"].is<const char*>()) card.status = str(c["status"]);
  card.progress = num(c["progress"]);
  card.updatedAt = parseIsoDate(c["updatedAt"] | "");
  card.staleAfter = parseIsoDate(c["staleAfter"] | "");
  card.deadline = parseIsoDate(c["deadline"] | "");

  JsonObjectConst comparison = c["comparison"];
  if (comparison) {
    card.comparisonValue = str(comparison["value"]);
    card.comparisonLabel = str(comparison["label"]);
    card.comparisonSignal = str(comparison["signal"]);
  }

  for (JsonObjectConst it : c["items"].as<JsonArrayConst>()) {
    CardItem item;
    item.title = str(it["title"]);
    item.subtitle = str(it["subtitle"]);
    item.value = str(it["value"]);
    item.unit = str(it["unit"]);
    item.status = str(it["status"]);
    item.amount = num(it["amount"]);
    card.items.push_back(item);
  }

  JsonObjectConst chart = c["chart"];
  if (chart) {
    for (JsonVariantConst p : chart["points"].as<JsonArrayConst>()) card.points.push_back(p.as<float>());
    card.chartStyle = str(chart["style"]);
    card.chartMin = num(chart["min"]);
    card.chartMax = num(chart["max"]);
    card.chartReference = num(chart["reference"]);
    card.grouped = strcmp(chart["stacking"] | "stacked", "grouped") == 0;
    for (JsonObjectConst sj : chart["series"].as<JsonArrayConst>()) {
      ChartSeries series;
      series.label = str(sj["label"]);
      for (JsonVariantConst p : sj["points"].as<JsonArrayConst>()) series.points.push_back(p.as<float>());
      series.role = str(sj["semantic"]["role"]);
      series.flow = str(sj["semantic"]["flow"]);
      series.signal = str(sj["semantic"]["signal"]);
      card.series.push_back(series);
    }
  }

  for (JsonObjectConst section : c["briefing"]["sections"].as<JsonArrayConst>()) {
    if (card.briefingText.length()) card.briefingText += "\n";
    card.briefingText += str(section["text"]);
  }

  for (JsonObjectConst a : c["actions"].as<JsonArrayConst>()) {
    bool destructive = strcmp(a["role"] | "normal", "destructive") == 0;
    bool confirm = a["confirm"] | false;
    if (destructive || confirm) {
      card.hadUnsafeActions = true;
      continue;
    }
    card.actions.push_back({str(a["id"]), str(a["label"])});
  }
  return card;
}

JsonDocument cardFilter() {
  JsonDocument f;
  JsonObject c = f["cards"].add<JsonObject>();
  for (const char* k : {"id", "template", "title", "subtitle", "value", "unit", "status", "progress",
                        "updatedAt", "staleAfter", "deadline"}) {
    c[k] = true;
  }
  c["comparison"] = true;
  JsonObject item = c["items"].add<JsonObject>();
  for (const char* k : {"title", "subtitle", "value", "unit", "status", "amount"}) item[k] = true;
  c["chart"]["points"] = true;
  c["chart"]["style"] = true;
  c["chart"]["min"] = true;
  c["chart"]["max"] = true;
  c["chart"]["reference"] = true;
  c["chart"]["stacking"] = true;
  JsonObject series = c["chart"]["series"].add<JsonObject>();
  series["label"] = true;
  series["points"] = true;
  series["semantic"] = true;
  c["briefing"]["sections"][0]["text"] = true;
  JsonObject action = c["actions"].add<JsonObject>();
  for (const char* k : {"id", "label", "role", "confirm"}) action[k] = true;
  return f;
}

}  // namespace

FetchResult fetchCards(std::vector<Card>& out) {
  return request("GET", "/v1/cards", "", [&](Stream& stream) -> String {
    JsonDocument doc;
    DeserializationError err =
        deserializeJson(doc, stream, DeserializationOption::Filter(cardFilter()));
    if (err) return String("bad JSON: ") + err.c_str();

    std::vector<Card> all;
    for (JsonObjectConst c : doc["cards"].as<JsonArrayConst>()) all.push_back(parseCard(c));

    out.clear();
    if (kConfiguredIdCount == 0) {
      out = std::move(all);
      return String();
    }
    for (size_t i = 0; i < kConfiguredIdCount; i++) {
      bool found = false;
      for (auto& card : all) {
        if (card.id == kConfiguredIds[i]) {
          out.push_back(card);
          found = true;
          break;
        }
      }
      if (!found) {
        Card placeholder;
        placeholder.id = kConfiguredIds[i];
        placeholder.title = kConfiguredIds[i];
        placeholder.value = "Not found";
        placeholder.subtitle = "No card with this id";
        placeholder.missing = true;
        out.push_back(placeholder);
      }
    }
    return String();
  });
}

FetchResult fetchScopes(bool& canRunActions) {
  canRunActions = false;
  return request("GET", "/v1/status", "", [&](Stream& stream) -> String {
    JsonDocument filter;
    filter["account"]["scopes"] = true;
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, stream, DeserializationOption::Filter(filter));
    if (err) return String("bad JSON: ") + err.c_str();
    for (JsonVariantConst s : doc["account"]["scopes"].as<JsonArrayConst>()) {
      if (strcmp(s | "", "actions:run") == 0) canRunActions = true;
    }
    return String();
  });
}

FetchResult runAction(const String& actionId, const String& cardId) {
  JsonDocument body;
  body["context"]["cardId"] = cardId;
  String json;
  serializeJson(body, json);
  return request("POST", "/v1/actions/" + urlEncode(actionId) + "/run", json,
                 [](Stream&) { return String(); });
}

// ISO-8601 with seconds, optional fraction, and Z or a +-HH:MM offset — the
// only shape the server emits or accepts.
time_t parseIsoDate(const char* s) {
  if (!s || strlen(s) < 19) return 0;
  int y, mo, d, h, mi, sec;
  if (sscanf(s, "%4d-%2d-%2dT%2d:%2d:%2d", &y, &mo, &d, &h, &mi, &sec) != 6) return 0;
  const char* p = s + 19;
  if (*p == '.') {
    p++;
    while (isdigit((unsigned char)*p)) p++;
  }
  long offset = 0;
  if (*p == '+' || *p == '-') {
    int oh = 0, om = 0;
    sscanf(p + 1, "%2d:%2d", &oh, &om);
    offset = (oh * 3600L + om * 60L) * (*p == '-' ? -1 : 1);
  }
  // Days from civil (Howard Hinnant), so no timezone state is involved.
  y -= mo <= 2;
  long era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400);
  unsigned doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  long days = era * 146097L + (long)doe - 719468L;
  return (time_t)(days * 86400L + h * 3600L + mi * 60L + sec - offset);
}
