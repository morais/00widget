import { describe, it, expect } from "vitest";
import { handleGuestPage } from "../src/guestPage";

/// The guest page is a third renderer, and the only one whose omissions are
/// silent: a card field it does not draw produces no error, no failing switch,
/// and a page that merely looks sparse. `producer` and `comparison` shipped and
/// were dropped here for exactly that reason, so these tests execute the script
/// the Worker actually serves rather than reading it for the right substrings.
///
/// There is no DOM in this suite (plain Node, no jsdom), so the shim provides
/// the three globals the script touches. Its `textContent` escapes `&`, `<` and
/// `>` and NOT quotes, which is exactly what browser text-node serialization
/// does — and the property the script's own esc() is built on.
async function renderGuestCard(payload: unknown): Promise<string> {
  const res = await handleGuestPage(new Request("https://x/app/g"), {} as never);
  const page = await res.text();
  const script = page.slice(
    page.indexOf("<script>") + "<script>".length,
    page.lastIndexOf("</script>"),
  );

  let captured = "";
  const makeElement = () => {
    const attrs: Record<string, string> = {};
    return {
      className: "",
      _text: "",
      set textContent(v: string) {
        this._text = String(v ?? "")
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;");
      },
      get innerHTML() {
        return this._text;
      },
      setAttribute(k: string, v: string) {
        attrs[k] = String(v);
      },
      get outerHTML() {
        const a = Object.entries(attrs)
          .map(([k, v]) => ` ${k}="${v.replace(/"/g, "&quot;")}"`)
          .join("");
        return `<a class="${this.className}"${a}>${this._text}</a>`;
      },
    };
  };
  const out = {
    set innerHTML(v: string) {
      captured = v;
    },
    get innerHTML() {
      return captured;
    },
  };

  // The script is an IIFE that reads location.hash and calls fetch at once.
  new Function("document", "location", "fetch", script)(
    { getElementById: (id: string) => (id === "out" ? out : null), createElement: makeElement },
    { hash: "#tok" },
    () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(payload) }),
  );
  // It renders inside a promise callback; let the microtask queue drain.
  await new Promise((r) => setTimeout(r, 0));
  return captured;
}

const card = (extra: Record<string, unknown>) => ({
  resourceKind: "card",
  expiresAt: "2026-12-01T00:00:00.000Z",
  card: { id: "c", template: "summary", title: "Trials", status: "good", ...extra },
});

describe("guest page — card fields it must not silently drop", () => {
  it("renders the producer's label under the title", async () => {
    const h = await renderGuestCard(
      card({ producer: { label: "Growth Agent", icon: "sparkles" } }),
    );
    expect(h).toContain('<p class="producer">Growth Agent</p>');
    // The icon names an SF Symbol, which a browser cannot resolve.
    expect(h).not.toContain("sparkles");
  });

  /// Mirrors DashboardCard.producerRepeatsSubtitle. This page draws the
  /// subtitle on every template, so unlike a card body there is no list-card
  /// exception to make here.
  it("drops the producer when the subtitle already opens with it", async () => {
    const h = await renderGuestCard(
      card({ subtitle: "Growth Agent · up 18 this week", producer: { label: "Growth Agent" } }),
    );
    expect(h).not.toContain('class="producer"');
    expect(h).toContain("Growth Agent · up 18 this week");
  });

  it("keeps a producer whose name is only a prefix of the subtitle's first word", async () => {
    // "Growth" is a different producer from "Growth Agent", and its
    // attribution says something the subtitle does not.
    const h = await renderGuestCard(
      card({ subtitle: "Growth Agent · up 18", producer: { label: "Growth" } }),
    );
    expect(h).toContain('<p class="producer">Growth</p>');
  });

  it("drops the producer when it is the whole subtitle", async () => {
    const h = await renderGuestCard(
      card({ subtitle: "Growth Agent", producer: { label: "Growth Agent" } }),
    );
    expect(h).not.toContain('class="producer"');
  });

  it("keeps a producer the subtitle does not open with", async () => {
    const h = await renderGuestCard(
      card({ subtitle: "of $30 today · $11.60 left", producer: { label: "Usage Agent" } }),
    );
    expect(h).toContain('<p class="producer">Usage Agent</p>');
  });

  it("renders a comparison with its signal class and mark", async () => {
    const h = await renderGuestCard(
      card({ value: "128", comparison: { value: "+18", label: "vs Monday", signal: "favorable" } }),
    );
    expect(h).toContain('class="cmp sig-favorable"');
    expect(h).toContain("+18");
    expect(h).toContain('<span class="cmp-label">vs Monday</span>');
  });

  it("colours a comparison by meaning rather than by sign", async () => {
    const h = await renderGuestCard(
      card({ value: "31", comparison: { value: "+18", label: "vs Monday", signal: "unfavorable" } }),
    );
    expect(h).toContain('class="cmp sig-unfavorable"');
  });

  it("omits both lines when the card carries neither", async () => {
    const h = await renderGuestCard(card({ value: "128" }));
    expect(h).not.toContain('class="producer"');
    expect(h).not.toContain('class="cmp');
  });

  /// esc() escapes text and not attribute values, so a signal the page does not
  /// recognise must reach no attribute at all rather than be interpolated.
  it("never interpolates an unrecognised signal into the class attribute", async () => {
    const h = await renderGuestCard(
      card({ value: "1", comparison: { value: "+1", label: "x", signal: '" onload="alert(1)' } }),
    );
    expect(h).toContain('class="cmp "');
    expect(h).not.toContain("onload");
  });

  it("escapes producer and comparison text", async () => {
    const h = await renderGuestCard(
      card({
        value: "1",
        producer: { label: "<script>x</script>" },
        comparison: { value: "<b>", label: "&", signal: "neutral" },
      }),
    );
    expect(h).not.toContain("<script>x");
    expect(h).toContain("&lt;script&gt;");
    expect(h).toContain("&lt;b&gt;");
  });
});
