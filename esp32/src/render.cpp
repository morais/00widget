#include "render.h"

#include <math.h>

namespace {

// --- Palette -----------------------------------------------------------------
// Close to the iOS system colours the app draws with, so a card reads the same
// on the desk as it does on the phone.

constexpr uint32_t kBackground = 0x000000;
constexpr uint32_t kPrimary = 0xFFFFFF;
constexpr uint32_t kSecondary = 0x9A9AA0;
constexpr uint32_t kTertiary = 0x48484D;
constexpr uint32_t kGreen = 0x30D158;
constexpr uint32_t kYellow = 0xFFD60A;
constexpr uint32_t kOrange = 0xFF9F0A;
constexpr uint32_t kRed = 0xFF453A;
constexpr uint32_t kBlue = 0x0A84FF;
constexpr uint32_t kGray = 0x8E8E93;
constexpr uint32_t kPurple = 0xBF5AF2;
constexpr uint32_t kTeal = 0x40CBE0;

uint16_t c565(uint32_t rgb) { return lgfx::color565(rgb >> 16, (rgb >> 8) & 0xFF, rgb & 0xFF); }

uint32_t mix(uint32_t a, uint32_t b, float t) {
  auto ch = [&](int shift) {
    float va = (a >> shift) & 0xFF, vb = (b >> shift) & 0xFF;
    return (uint32_t)lroundf(va + (vb - va) * t) << shift;
  };
  return ch(16) | ch(8) | ch(0);
}

uint32_t statusColor(const String& status) {
  if (status == "good" || status == "finished") return kGreen;
  if (status == "warning") return kOrange;
  if (status == "critical") return kRed;
  if (status == "running") return kBlue;
  return kGray;  // unknown, paused, offline
}

uint32_t signalColor(const String& signal) {
  if (signal == "favorable") return kGreen;
  if (signal == "caution") return kOrange;
  if (signal == "unfavorable") return kRed;
  return kSecondary;
}

// --- Fonts -------------------------------------------------------------------
// efont covers Latin, Greek, Cyrillic and general punctuation as well as CJK,
// so card text in any of those survives; it stops at 24px, so the headline
// uses the larger proportional Gothic and falls back where it lacks a glyph.

const lgfx::IFont* const kSmall = &fonts::efontCN_14;
const lgfx::IFont* const kBody = &fonts::efontCN_16;
const lgfx::IFont* const kBold = &fonts::efontCN_16_b;
const lgfx::IFont* const kLarge = &fonts::efontCN_24_b;
// Largest first; the headline takes the first one it fits in.
const lgfx::IFont* const kHeadlines[] = {
    &fonts::lgfxJapanGothicP_40, &fonts::lgfxJapanGothicP_32, &fonts::lgfxJapanGothicP_28,
    &fonts::efontCN_24_b, &fonts::efontCN_16_b,
};

constexpr int kW = 320;
constexpr int kH = 170;
constexpr int kMargin = 10;
constexpr int kHeaderH = 26;
constexpr int kFooterY = kH - 20;

// --- Text --------------------------------------------------------------------

bool hasGlyph(const lgfx::IFont* font, uint32_t cp) {
  if (cp > 0xFFFF) return false;
  lgfx::FontMetrics m;
  font->getDefaultMetric(&m);
  return font->updateFontMetric(&m, (uint16_t)cp);
}

void appendUtf8(String& out, uint32_t cp) {
  char buf[5] = {0};
  if (cp < 0x80) {
    buf[0] = cp;
  } else if (cp < 0x800) {
    buf[0] = 0xC0 | (cp >> 6);
    buf[1] = 0x80 | (cp & 0x3F);
  } else if (cp < 0x10000) {
    buf[0] = 0xE0 | (cp >> 12);
    buf[1] = 0x80 | ((cp >> 6) & 0x3F);
    buf[2] = 0x80 | (cp & 0x3F);
  } else {
    buf[0] = 0xF0 | (cp >> 18);
    buf[1] = 0x80 | ((cp >> 12) & 0x3F);
    buf[2] = 0x80 | ((cp >> 6) & 0x3F);
    buf[3] = 0x80 | (cp & 0x3F);
  }
  out += buf;
}

// What to try, in order, when a font lacks a code point. Producers write
// typographic punctuation freely ("57–69", "−0.11%", "Oct 15 · 63"), and a
// silently dropped minus sign changes what a number says.
const char* substitute(uint32_t cp) {
  switch (cp) {
    case 0x2212: case 0x2013: case 0x2014: case 0x2010: case 0x2011: return "-";
    case 0x00B7: case 0x2022: case 0x2027: return "\xC2\xB7|-";
    case 0x2018: case 0x2019: case 0x2032: return "'";
    case 0x201C: case 0x201D: case 0x2033: return "\"";
    case 0x2026: return "...";
    case 0x00A0: case 0x2009: case 0x202F: case 0x2007: return " ";
    case 0x2191: return "^";
    case 0x2193: return "v";
    case 0x2192: return "->";
    case 0x00B0: return "\xC2\xB0|deg";
  }
  return nullptr;
}

const char* latinBase(uint32_t cp) {
  static const char* table =
      "AAAAAAACEEEEIIII"  // C0-CF
      "DNOOOOOxOUUUUYTs"  // D0-DF
      "aaaaaaaceeeeiiii"  // E0-EF
      "dnooooo/ouuuuyty";  // F0-FF
  static char out[2];
  if (cp < 0xC0 || cp > 0xFF) return nullptr;
  out[0] = table[cp - 0xC0];
  out[1] = 0;
  return out;
}

uint32_t decodeUtf8(const char*& p) {
  uint8_t c = *p++;
  if (c < 0x80) return c;
  int extra = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
  uint32_t cp = c & (0x3F >> extra);
  for (int i = 0; i < extra && (*p & 0xC0) == 0x80; i++) cp = (cp << 6) | (*p++ & 0x3F);
  return cp;
}

// Rewrites `s` so every code point is one `font` can draw.
String forFont(const lgfx::IFont* font, const String& s) {
  String out;
  out.reserve(s.length());
  const char* p = s.c_str();
  while (*p) {
    uint32_t cp = decodeUtf8(p);
    if (cp == '\n' || hasGlyph(font, cp)) {
      appendUtf8(out, cp);
      continue;
    }
    const char* options = substitute(cp);
    if (!options) options = latinBase(cp);
    if (!options) continue;
    // Alternatives are '|'-separated; take the first the font can draw whole.
    String alt(options);
    int start = 0;
    while (start <= (int)alt.length()) {
      int bar = alt.indexOf('|', start);
      String candidate = alt.substring(start, bar < 0 ? alt.length() : bar);
      bool ok = true;
      for (const char* q = candidate.c_str(); *q && ok;) ok = hasGlyph(font, decodeUtf8(q));
      if (ok) {
        out += candidate;
        break;
      }
      if (bar < 0) break;
      start = bar + 1;
    }
  }
  return out;
}

int textWidth(LGFX_Sprite& g, const lgfx::IFont* font, const String& s) {
  g.setFont(font);
  return g.textWidth(s);
}

// Draws `s` cut to `maxW` with an ellipsis. Returns the width drawn.
int drawFit(LGFX_Sprite& g, const lgfx::IFont* font, const String& raw, int x, int y, int maxW,
            uint32_t color, textdatum_t datum = top_left) {
  g.setFont(font);
  String s = forFont(font, raw);
  s.replace("\n", " ");
  if (g.textWidth(s) > maxW) {
    String ellipsis = hasGlyph(font, 0x2026) ? "\xE2\x80\xA6" : "...";
    int ew = g.textWidth(ellipsis);
    // Trim whole UTF-8 sequences from the end until it fits.
    while (s.length() && g.textWidth(s) + ew > maxW) {
      int i = s.length() - 1;
      while (i > 0 && ((uint8_t)s[i] & 0xC0) == 0x80) i--;
      s.remove(i);
    }
    s.trim();
    s += ellipsis;
  }
  g.setTextColor(c565(color));
  g.setTextDatum(datum);
  g.drawString(s, x, y);
  g.setTextDatum(top_left);
  return g.textWidth(s);
}

// Word-wraps into at most `maxLines`, ellipsising the last. Returns lines used.
int drawWrapped(LGFX_Sprite& g, const lgfx::IFont* font, const String& raw, int x, int y, int w,
                int maxLines, int lineH, uint32_t color) {
  g.setFont(font);
  String s = forFont(font, raw);
  int line = 0;
  int pos = 0;
  while (pos < (int)s.length() && line < maxLines) {
    int nl = s.indexOf('\n', pos);
    int paraEnd = nl < 0 ? s.length() : nl;
    String para = s.substring(pos, paraEnd);
    pos = paraEnd + 1;
    while (para.length() && line < maxLines) {
      // Longest prefix that fits, broken at a space when there is one.
      int cut = para.length();
      while (cut > 0 && g.textWidth(para.substring(0, cut)) > w) {
        int sp = para.lastIndexOf(' ', cut - 1);
        cut = sp > 0 ? sp : cut - 1;
      }
      if (cut == 0) cut = 1;
      bool last = line == maxLines - 1;
      String rest = para.substring(cut);
      rest.trim();
      bool more = rest.length() || pos < (int)s.length();
      if (last && more) {
        drawFit(g, font, para + " " + s.substring(pos), x, y + line * lineH, w, color);
      } else {
        g.setTextColor(c565(color));
        g.drawString(para.substring(0, cut), x, y + line * lineH);
      }
      line++;
      para = rest;
    }
  }
  return line;
}

// --- Time --------------------------------------------------------------------

String ago(time_t then, time_t now) {
  if (!then || !now) return String();
  long d = (long)(now - then);
  if (d < 60) return "now";
  if (d < 3600) return String(d / 60) + "m ago";
  if (d < 86400) return String(d / 3600) + "h ago";
  return String(d / 86400) + "d ago";
}

String countdown(time_t deadline, time_t now) {
  long d = (long)(deadline - now);
  long a = labs(d);
  String span;
  if (a < 60) span = String(a) + "s";
  else if (a < 3600) span = String(a / 60) + "m";
  else if (a < 86400) span = String(a / 3600) + "h " + String((a % 3600) / 60) + "m";
  else span = String(a / 86400) + "d " + String((a % 86400) / 3600) + "h";
  return d >= 0 ? "Due in " + span : "Overdue " + span;
}

// --- Chrome ------------------------------------------------------------------

void drawHeader(LGFX_Sprite& g, const Card& card, const ScreenState& s, uint32_t accent,
                const String& right) {
  g.fillCircle(kMargin + 4, 13, 5, c565(accent));
  int rightW = 0;
  if (right.length()) {
    g.setFont(kSmall);
    rightW = g.textWidth(right) + 8;
    drawFit(g, kSmall, right, kW - kMargin, 6, 120, kSecondary, top_right);
  }
  drawFit(g, kBold, card.title, kMargin + 16, 5, kW - kMargin * 2 - 16 - rightW, kPrimary);
}

String clockText(time_t now) {
  if (!now) return String();
  struct tm t;
  localtime_r(&now, &t);
  char buf[8];
  strftime(buf, sizeof buf, "%H:%M", &t);
  return buf;
}

// `note` fills the right-hand slot when the card has no action to hint at.
void drawFooter(LGFX_Sprite& g, const Card* card, const ScreenState& s, const String& note) {
  int y = kFooterY + 4;
  int x = kMargin;

  // Position: dots while they fit, a counter past that.
  if (s.count > 1 && s.count <= 12) {
    for (size_t i = 0; i < s.count; i++) {
      g.fillCircle(x + 3, y + 7, i == s.index ? 3 : 2, c565(i == s.index ? kPrimary : kTertiary));
      x += 9;
    }
    x += 6;
  } else if (s.count > 12) {
    x += drawFit(g, kSmall, String(s.index + 1) + "/" + String(s.count), x, y, 60, kSecondary) + 8;
  }

  // Freshness: the card's own age, unless the device itself is out of date,
  // which matters more and would otherwise make every card look current.
  String status;
  uint32_t statusCol = kSecondary;
  if (s.fetchError.length()) {
    status = "Offline";
    if (s.lastSuccess && s.now) status += " · " + ago(s.lastSuccess, s.now);
    statusCol = kOrange;
  } else if (card && card->staleAfter && s.now && s.now > card->staleAfter) {
    status = "Stale · " + ago(card->updatedAt, s.now);
    statusCol = kOrange;
  } else if (card) {
    status = ago(card->updatedAt, s.now);
  }

  // Action hint on the right.
  String hint;
  uint32_t hintCol = kSecondary;
  if (card && !card->actions.empty()) {
    if (s.canRunActions) {
      const CardAction& a = card->actions[s.selectedAction % card->actions.size()];
      hint = "Hold: " + a.label;
      if (card->actions.size() > 1) {
        hint = String(s.selectedAction % card->actions.size() + 1) + "/" +
               String(card->actions.size()) + " " + hint;
      }
      hintCol = kBlue;
    } else {
      hint = "Read-only token";
      hintCol = kTertiary;
    }
  } else if (card && card->hadUnsafeActions) {
    hint = "Actions in app";
    hintCol = kTertiary;
  } else {
    hint = note;
  }

  int hintW = 0;
  if (hint.length()) hintW = drawFit(g, kSmall, hint, kW - kMargin, y, 170, hintCol, top_right) + 8;
  if (status.length()) drawFit(g, kSmall, status, x, y, kW - kMargin - hintW - x, statusCol);
}

// --- Bodies ------------------------------------------------------------------

// Headline value with its unit, in the largest font that fits. Returns the
// bottom edge.
int drawHeadline(LGFX_Sprite& g, const Card& card, int y, int maxW, uint32_t color,
                 size_t firstFont = 0) {
  if (!card.value.length()) return y;
  String unit = card.unit;
  for (size_t i = firstFont; i < sizeof(kHeadlines) / sizeof(kHeadlines[0]); i++) {
    const lgfx::IFont* f = kHeadlines[i];
    String v = forFont(f, card.value);
    int unitW = unit.length() ? textWidth(g, kBody, forFont(kBody, unit)) + 6 : 0;
    int vw = textWidth(g, f, v);
    bool lastFont = i == sizeof(kHeadlines) / sizeof(kHeadlines[0]) - 1;
    if (vw + unitW <= maxW || lastFont) {
      g.setFont(f);
      int h = g.fontHeight();
      int drawn = drawFit(g, f, card.value, kMargin, y, maxW - unitW, color);
      if (unit.length()) {
        g.setFont(kBody);
        // Sit the unit on the headline's baseline rather than its top.
        drawFit(g, kBody, unit, kMargin + drawn + 6, y + h - g.fontHeight() - h / 10, unitW,
                kSecondary);
      }
      return y + h;
    }
  }
  return y;
}

int drawComparison(LGFX_Sprite& g, const Card& card, int y) {
  if (!card.comparisonValue.length()) return y;
  int w = drawFit(g, kBold, card.comparisonValue, kMargin, y, 140, signalColor(card.comparisonSignal));
  if (card.comparisonLabel.length()) {
    drawFit(g, kBody, card.comparisonLabel, kMargin + w + 8, y, kW - kMargin * 2 - w - 8, kSecondary);
  }
  return y + 20;
}

void drawBar(LGFX_Sprite& g, int x, int y, int w, int h, float fraction, uint32_t color) {
  fraction = fminf(fmaxf(fraction, 0), 1);
  g.fillRoundRect(x, y, w, h, h / 2, c565(kTertiary));
  int fw = (int)lroundf(w * fraction);
  if (fw > 0) g.fillRoundRect(x, y, max(fw, h), h, h / 2, c565(color));
}

// --- Multi-series bars ----------------------------------------------------------
// Port of ChartSeriesPalette (ios/Sources/Shared/Rendering/ChartSupplementView.swift):
// a series' signal, then its flow, picks its colour, and a colour already taken
// passes to the next unused default so equal hints never merge two segments.
// Keep the two in step.

std::vector<uint32_t> seriesColors(const std::vector<ChartSeries>& series) {
  static const uint32_t kDefaults[] = {kBlue, kPurple, kTeal, kOrange};
  std::vector<uint32_t> out;
  for (size_t i = 0; i < series.size(); i++) {
    const ChartSeries& sr = series[i];
    uint32_t preferred = 0;
    bool hasPreferred = true;
    if (sr.signal == "favorable") preferred = kGreen;
    else if (sr.signal == "neutral") preferred = kGray;
    else if (sr.signal == "caution") preferred = kOrange;
    else if (sr.signal == "unfavorable") preferred = kRed;
    else if (sr.flow == "inbound") preferred = kTeal;
    else if (sr.flow == "outbound") preferred = kPurple;
    else hasPreferred = false;

    auto used = [&](uint32_t c) {
      for (uint32_t u : out) if (u == c) return true;
      return false;
    };
    uint32_t pick = kDefaults[i % 4];
    if (hasPreferred && !used(preferred)) {
      pick = preferred;
    } else {
      for (size_t k = 0; k < 4; k++) {
        uint32_t c = kDefaults[(i + k) % 4];
        if (!used(c)) {
          pick = c;
          break;
        }
      }
    }
    out.push_back(pick);
  }
  return out;
}

// Role is drawn as strength, as iOS does with opacity; on a black panel that
// is a blend toward the background.
float roleStrength(const String& role) {
  if (role == "forecast") return 0.48f;
  if (role == "baseline") return 0.55f;
  if (role == "target") return 0.72f;
  if (role == "capacity") return 0.35f;
  if (role == "remainder") return 0.45f;
  return 0.88f;
}

int legendWidth(LGFX_Sprite& g, const Card& card) {
  int w = 0;
  for (auto& sr : card.series) w += 10 + textWidth(g, kSmall, forFont(kSmall, sr.label)) + 8;
  return w > 0 ? w - 8 : 0;
}

void drawLegend(LGFX_Sprite& g, const Card& card, int right, int y) {
  auto colors = seriesColors(card.series);
  int x = right - legendWidth(g, card);
  for (size_t i = 0; i < card.series.size(); i++) {
    uint32_t c = mix(kBackground, colors[i], roleStrength(card.series[i].role));
    g.fillRoundRect(x, y + 4, 7, 7, 2, c565(c));
    x += 10 + drawFit(g, kSmall, card.series[i].label, x + 10, y, 120, kSecondary) + 8;
  }
}

void drawSeriesBars(LGFX_Sprite& g, const Card& card, int x, int y, int w, int h) {
  size_t n = SIZE_MAX;
  for (auto& sr : card.series) n = min(n, sr.points.size());
  if (n < 1 || n == SIZE_MAX) return;
  size_t k = card.series.size();
  auto colors = seriesColors(card.series);

  float hi = 0;
  for (size_t i = 0; i < n; i++) {
    float sum = 0;
    for (auto& sr : card.series) {
      float v = fmaxf(sr.points[i], 0);
      sum += v;
      hi = fmaxf(hi, v);
    }
    if (!card.grouped) hi = fmaxf(hi, sum);
  }
  if (!isnan(card.chartMax)) hi = card.chartMax;
  if (hi <= 0) hi = 1;

  float step = (float)w / n;
  int barW = max(1, (int)(step * 0.75f));
  int base = y + h;
  for (size_t i = 0; i < n; i++) {
    int bx = x + (int)(i * step + (step - barW) / 2);
    int stackTop = base;
    for (size_t j = 0; j < k; j++) {
      float v = fmaxf(card.series[j].points[i], 0);
      int bh = (int)lroundf(fminf(v / hi, 1) * h);
      if (bh <= 0) continue;
      uint16_t c = c565(mix(kBackground, colors[j], roleStrength(card.series[j].role)));
      if (card.grouped) {
        int sw = max(1, barW / (int)k);
        g.fillRect(bx + j * sw, base - bh, max(1, sw - (sw > 2 ? 1 : 0)), bh, c);
      } else {
        g.fillRect(bx, stackTop - bh, barW, bh, c);
        stackTop -= bh;
      }
    }
  }
  if (!isnan(card.chartReference)) {
    int ry = base - (int)lroundf(fminf(card.chartReference / hi, 1) * h);
    for (int dx = x; dx < x + w; dx += 7) g.drawFastHLine(dx, ry, 4, c565(kSecondary));
  }
}

void drawChart(LGFX_Sprite& g, const Card& card, int x, int y, int w, int h, uint32_t color) {
  const auto& pts = card.points;
  if (pts.size() < 2) return;
  bool bars = card.chartStyle == "bar" || card.chartStyle == "delta";
  float lo = INFINITY, hi = -INFINITY;
  for (float p : pts) {
    lo = fminf(lo, p);
    hi = fmaxf(hi, p);
  }
  if (!isnan(card.chartReference)) {
    lo = fminf(lo, card.chartReference);
    hi = fmaxf(hi, card.chartReference);
  }
  if (card.chartStyle == "delta" || card.chartStyle == "bar") lo = fminf(lo, 0);
  if (card.chartStyle == "delta") hi = fmaxf(hi, 0);
  if (!isnan(card.chartMin)) lo = card.chartMin;
  if (!isnan(card.chartMax)) hi = card.chartMax;
  if (hi - lo < 1e-6f) {
    hi += 1;
    lo -= 1;
  }
  auto py = [&](float v) { return y + h - 1 - (int)lroundf((v - lo) / (hi - lo) * (h - 1)); };
  size_t n = pts.size();

  if (bars) {
    float step = (float)w / n;
    int bw = max(1, (int)(step * 0.7f));
    int zero = py(fmaxf(lo, fminf(0.0f, hi)));
    for (size_t i = 0; i < n; i++) {
      int bx = x + (int)(i * step + (step - bw) / 2);
      int top = py(pts[i]);
      uint32_t col = card.chartStyle == "delta" && pts[i] < 0 ? kOrange : color;
      g.fillRect(bx, min(top, zero), bw, max(1, abs(zero - top)), c565(col));
    }
  } else {
    uint16_t fill = c565(mix(kBackground, color, 0.22f));
    uint16_t line = c565(color);
    int prevX = x, prevY = py(pts[0]);
    for (size_t i = 1; i < n; i++) {
      int cx = x + (int)lroundf((float)i * (w - 1) / (n - 1));
      int cy = py(pts[i]);
      // Area under the segment, column by column.
      for (int col = prevX; col <= cx; col++) {
        float t = cx == prevX ? 0 : (float)(col - prevX) / (cx - prevX);
        int ly = prevY + (int)lroundf((cy - prevY) * t);
        g.drawFastVLine(col, ly, y + h - ly, fill);
      }
      g.drawWideLine(prevX, prevY, cx, cy, 1.2f, line);
      prevX = cx;
      prevY = cy;
    }
    g.fillCircle(prevX, prevY, 3, line);
  }

  if (!isnan(card.chartReference)) {
    int ry = py(card.chartReference);
    for (int dx = x; dx < x + w; dx += 7) g.drawFastHLine(dx, ry, 4, c565(kSecondary));
  }
}

void bodySummary(LGFX_Sprite& g, const Card& card, const ScreenState& s, uint32_t accent) {
  int y = kHeaderH + 6;
  y = drawHeadline(g, card, y, kW - kMargin * 2, kPrimary) + 4;
  if (card.subtitle.length()) {
    drawFit(g, kBody, card.subtitle, kMargin, y, kW - kMargin * 2, kSecondary);
    y += 20;
  }
  y = drawComparison(g, card, y);

  if (card.templ == "progress" && !isnan(card.progress)) {
    y += 4;
    int pctW = textWidth(g, kBold, "100%") + 8;
    drawBar(g, kMargin, y + 3, kW - kMargin * 2 - pctW, 10, card.progress, accent);
    drawFit(g, kBold, String((int)lroundf(card.progress * 100)) + "%", kW - kMargin, y, pctW,
            kPrimary, top_right);
    y += 20;
  }

  if (card.templ == "breakdown" && !card.items.empty()) {
    static const uint32_t kSegments[] = {kBlue, kGreen, kOrange, 0xBF5AF2, 0x64D2FF, kYellow};
    float total = 0;
    for (auto& it : card.items) total += isnan(it.amount) ? 0 : fmaxf(it.amount, 0);
    if (total > 0) {
      int bx = kMargin, bw = kW - kMargin * 2;
      float acc = 0;
      for (size_t i = 0; i < card.items.size(); i++) {
        float a = isnan(card.items[i].amount) ? 0 : fmaxf(card.items[i].amount, 0);
        int x0 = bx + (int)lroundf(acc / total * bw);
        acc += a;
        int x1 = bx + (int)lroundf(acc / total * bw);
        if (x1 > x0) g.fillRect(x0, y + 2, max(1, x1 - x0 - 1), 10, c565(kSegments[i % 6]));
      }
      y += 18;
      int lx = kMargin;
      for (size_t i = 0; i < card.items.size() && y < kFooterY - 14; i++) {
        String label = card.items[i].title;
        if (card.items[i].value.length()) label += " " + card.items[i].value;
        int w = textWidth(g, kSmall, forFont(kSmall, label)) + 16;
        if (lx + w > kW - kMargin && lx > kMargin) {
          lx = kMargin;
          y += 16;
          if (y >= kFooterY - 14) break;
        }
        g.fillRect(lx, y + 4, 7, 7, c565(kSegments[i % 6]));
        lx += 10 + drawFit(g, kSmall, label, lx + 10, y, kW - kMargin - lx - 10, kSecondary) + 8;
      }
      y += 16;
    }
  }

  if (card.deadline && s.now && y < kFooterY - 18) {
    drawFit(g, kBold, countdown(card.deadline, s.now), kMargin, y,
            kW - kMargin * 2, card.deadline < s.now ? kRed : kPrimary);
    y += 20;
  }

  if (card.briefingText.length() && y < kFooterY - 16) {
    drawWrapped(g, kSmall, card.briefingText, kMargin, y + 2, kW - kMargin * 2,
                (kFooterY - 2 - y) / 16, 16, kPrimary);
  }
}

void bodyChart(LGFX_Sprite& g, const Card& card, const ScreenState& s, uint32_t accent) {
  int y = kHeaderH + 4;
  // Leave the plot most of the room: start the headline one size down.
  y = drawHeadline(g, card, y, kW - kMargin * 2, kPrimary, 1) + 2;
  bool multi = !card.series.empty() && card.templ == "chart";
  // The legend shares the line under the headline when it fits beside what
  // is already there, and takes a line of the plot's height when it doesn't.
  int legendW = multi ? legendWidth(g, card) : 0;
  int lineY = y;
  int besideW = 0;
  if (card.comparisonValue.length()) {
    y = drawComparison(g, card, y);
    besideW = kW;  // comparison width is not measured; never share its line
  } else if (card.subtitle.length()) {
    int avail = kW - kMargin * 2 - (multi ? legendW + 12 : 0);
    int sw = textWidth(g, kBody, forFont(kBody, card.subtitle));
    besideW = sw <= avail ? sw : kW;
    drawFit(g, kBody, card.subtitle, kMargin, y, besideW == kW ? kW - kMargin * 2 : avail, kSecondary);
    y += 20;
  }
  if (multi) {
    if (besideW + legendW + 12 <= kW - kMargin * 2) {
      drawLegend(g, card, kW - kMargin, lineY + 2);
      if (y == lineY) y += 20;
    } else {
      drawLegend(g, card, kW - kMargin, y);
      y += 16;
    }
  }
  int top = y + 4, bottom = kFooterY - 4;
  if (card.templ == "history" && !card.items.empty()) {
    size_t n = min<size_t>(card.items.size(), 20);
    int gap = 4;
    int pw = min(28, (kW - kMargin * 2 - gap * ((int)n - 1)) / (int)n);
    int ph = min(28, bottom - top);
    int py = top + (bottom - top - ph) / 2;
    // Oldest first, newest at the right, as everywhere else.
    for (size_t i = 0; i < n; i++) {
      const CardItem& it = card.items[card.items.size() - n + i];
      g.fillRoundRect(kMargin + i * (pw + gap), py, pw, ph, 4, c565(statusColor(it.status)));
    }
  } else if (multi && bottom - top > 12) {
    drawSeriesBars(g, card, kMargin, top, kW - kMargin * 2, bottom - top);
  } else if (card.points.size() >= 2 && bottom - top > 12) {
    drawChart(g, card, kMargin, top, kW - kMargin * 2, bottom - top, accent);
  } else if (!isnan(card.progress)) {
    drawBar(g, kMargin, top + 4, kW - kMargin * 2, 10, card.progress, accent);
  }
}

// Returns how many rows did not fit.
size_t bodyList(LGFX_Sprite& g, const Card& card, const ScreenState& s, uint32_t accent) {
  int y = kHeaderH + 4;
  if (card.value.length()) {
    // A single line: the headline in a mid size with the comparison beside it.
    int w = drawFit(g, kLarge, card.value, kMargin, y, 180, kPrimary);
    int x = kMargin + w + 6;
    if (card.unit.length()) x += drawFit(g, kBody, card.unit, x, y + 6, 80, kSecondary) + 10;
    if (card.comparisonValue.length() && x < kW - 60) {
      drawFit(g, kBold, card.comparisonValue, kW - kMargin, y + 6, kW - kMargin - x,
              signalColor(card.comparisonSignal), top_right);
    }
    y += 30;
  } else if (card.subtitle.length()) {
    drawFit(g, kBody, card.subtitle, kMargin, y, kW - kMargin * 2, kSecondary);
    y += 22;
  }

  constexpr int kRowH = 20;
  float maxAmount = 0;
  for (auto& it : card.items) {
    if (!isnan(it.amount)) maxAmount = fmaxf(maxAmount, fabsf(it.amount));
  }
  size_t room = (kFooterY - y) / kRowH;
  size_t shown = min(room, card.items.size());
  for (size_t i = 0; i < shown; i++) {
    const CardItem& it = card.items[i];
    int ry = y + i * kRowH;
    if (maxAmount > 0 && !isnan(it.amount)) {
      int bw = (int)lroundf(fabsf(it.amount) / maxAmount * (kW - kMargin * 2));
      g.fillRoundRect(kMargin - 4, ry, bw + 4, kRowH - 3, 3, c565(mix(kBackground, accent, 0.25f)));
    }
    uint32_t dot = it.status.length() ? statusColor(it.status) : kTertiary;
    g.fillCircle(kMargin + 2, ry + 8, 3, c565(dot));
    String value = it.value;
    if (it.unit.length()) value += " " + it.unit;
    int vw = value.length() ? drawFit(g, kBold, value, kW - kMargin, ry + 1, 150, kPrimary, top_right) + 10 : 0;
    drawFit(g, kBody, it.title, kMargin + 12, ry + 1, kW - kMargin * 2 - 12 - vw, kPrimary);
  }
  return card.items.size() - shown;
}

}  // namespace

void renderCard(LGFX_Sprite& g, const Card& card, const ScreenState& s) {
  g.fillScreen(c565(kBackground));
  bool stale = card.staleAfter && s.now && s.now > card.staleAfter;
  uint32_t accent = card.missing ? kGray : statusColor(card.status);
  if (stale) accent = mix(accent, kBackground, 0.5f);

  drawHeader(g, card, s, accent, clockText(s.now));

  String note;
  if (card.templ == "list" && !card.items.empty()) {
    size_t hidden = bodyList(g, card, s, accent);
    if (hidden) note = "+" + String(hidden) + " more";
  } else if (card.templ == "chart" || card.templ == "history") {
    bodyChart(g, card, s, accent);
  } else {
    bodySummary(g, card, s, accent);
  }

  drawFooter(g, &card, s, note);

  if (s.toast.length()) {
    g.fillRoundRect(kMargin, kFooterY - 30, kW - kMargin * 2, 28, 8, c565(0x1C1C1E));
    drawFit(g, kBold, s.toast, kW / 2, kFooterY - 24, kW - kMargin * 4, s.toastColor, top_center);
  }
}

void renderMessage(LGFX_Sprite& g, const String& title, const String& body, uint32_t accent,
                   const ScreenState& s) {
  g.fillScreen(c565(kBackground));
  g.fillCircle(kMargin + 4, 13, 5, c565(accent));
  drawFit(g, kBold, "00Widget", kMargin + 16, 5, 200, kSecondary);
  String clock = clockText(s.now);
  if (clock.length()) drawFit(g, kSmall, clock, kW - kMargin, 6, 80, kSecondary, top_right);
  drawFit(g, kLarge, title, kMargin, 44, kW - kMargin * 2, kPrimary);
  drawWrapped(g, kBody, body, kMargin, 80, kW - kMargin * 2, 4, 20, kSecondary);
}
