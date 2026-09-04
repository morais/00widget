import { describe, it, expect } from "vitest";
import { MCP_GUIDE_SECTIONS, renderMcpGuide, type McpGuideSection } from "../src/mcp";
import { llmsMarkdown } from "../src/generated/llmsDoc";

const BASE = "https://api.00widget.com";
const sections = Object.keys(MCP_GUIDE_SECTIONS) as McpGuideSection[];
const render = (s: McpGuideSection) => renderMcpGuide(s, BASE);

/// The guide is the largest thing this server puts into an agent's context —
/// `essentials` alone is around 16k tokens, against roughly 46k for the whole
/// of `tools/list` — and until now nothing measured it. These are the four
/// properties that stop it drifting: it cannot silently grow, nothing can
/// become unreachable, the rules whose absence is silent stay in, and a
/// narrowed section cannot point at a heading it does not contain.
describe("MCP integration guide", () => {
  /// A ceiling, not a target. Set a little above where the sections sit today,
  /// so ordinary editing is free and a section-sized addition is a decision
  /// somebody makes on purpose rather than one that lands in every agent's
  /// context unnoticed.
  ///
  /// Raised once, deliberately: documenting `producer`, `comparison`, and the
  /// derived "Needs you" badge added ~3.9k characters to `cards`, which
  /// `essentials` and `everything` carry too. The alternative was leaving three
  /// shipped fields undocumented, which is the failure this file exists to
  /// prevent — an agent cannot publish what the guide never mentions, and
  /// "Needs you" has no field to discover from the schema at all.
  const BUDGETS: Record<McpGuideSection, number> = {
    essentials: 70_000,
    cards: 38_000,
    "live-activities": 34_000,
    actions: 9_000,
    everything: 105_000,
  };

  it.each(sections)("%s stays inside its context budget", (section) => {
    expect(render(section).length).toBeLessThanOrEqual(BUDGETS[section]);
  });

  /// The failure mode of trimming: a rule that survives in the document and in
  /// no section any agent would ever ask for. It has happened once already —
  /// "Operator checklist for agents" is in no section but `everything`, which
  /// was found by accident rather than by a test.
  it("every section of the document is reachable through some named section", () => {
    const headings = llmsMarkdown
      .split("\n")
      .filter((line) => line.startsWith("## "))
      .map((line) => line.slice(3).trim());
    const named = new Set(
      sections.flatMap((s) => (MCP_GUIDE_SECTIONS[s] ?? []) as readonly string[]),
    );
    const unreachable = headings.filter((h) => !named.has(h));
    // `everything` returns the whole document, so nothing is ever truly lost —
    // but a heading no *narrow* section carries is one an agent following the
    // steering will never see. Listing them here is the point: adding to this
    // list has to be deliberate.
    expect(unreachable).toEqual([
      "Choose the right connection",
      "TL;DR for API integrations",
      "Operator checklist for agents",
      "Get the operator to give you",
      "If your host speaks MCP",
      "Ask what your integration can actually reach",
      "Size limits",
      "Compatibility",
      "How fast a widget actually updates",
      "Snippets",
      "Notes for Cloudflare Workers callers",
      "Where to look for more",
    ]);
  });

  /// The rules whose absence is silent: nothing errors, the publish succeeds,
  /// and the operator gets a worse widget. Each of these cost a real incident.
  it.each([
    ["the card-versus-Live-Activity choice", "First check you want a card at all"],
    ["the frozen title", "frozen when the activity starts"],
    ["items suppressing a chart", "compete for the same space"],
    ["surface budgets", "How much room each surface actually has"],
    ["jobs with named parts", "A job with named parts"],
    // Publishing an attention status with no `actions` succeeds and simply
    // does not badge. There is no field to discover this from, so the guide
    // is the only place an agent can learn it.
    ["the derived Needs you badge", "Asking the operator to step in"],
    ["who published a card", "**CardProducer**"],
    ["the change beside the headline", "**CardComparison**"],
  ])("essentials keeps %s", (_name, needle) => {
    expect(render("essentials")).toContain(needle);
  });

  it("cards and live-activities each keep their own half's rules", () => {
    expect(render("cards")).toContain("First check you want a card at all");
    expect(render("cards")).toContain("Asking the operator to step in");
    expect(render("cards")).toContain("**CardProducer**");
    expect(render("cards")).toContain("**CardComparison**");
    expect(render("live-activities")).toContain("frozen when the activity starts");
    expect(render("live-activities")).toContain("compete for the same space");
  });

  /// Steering an agent to one half only works if that half can tell it where
  /// the other one is. A link into a heading the rendering does not contain is
  /// a dead end an agent reads as "this product cannot do that".
  it.each(sections)("%s has no link to a heading it does not contain", (section) => {
    const markdown = render(section);
    const anchors = [...markdown.matchAll(/\]\(#([a-z0-9-]+)\)/g)].map((m) => m[1]);
    const slugs = new Set(
      markdown
        .split("\n")
        .filter((line) => /^#{1,4} /.test(line))
        .map((line) =>
          line
            .replace(/^#+ /, "")
            .toLowerCase()
            .replace(/`/g, "")
            .replace(/[^a-z0-9 -]/g, "")
            .trim()
            .replace(/\s+/g, "-"),
        ),
    );
    expect([...new Set(anchors.filter((a) => !slugs.has(a)))]).toEqual([]);
  });

  /// Every narrow section must say what it left out, or narrowing turns into
  /// publishing against rules the agent never saw.
  it.each(sections.filter((s) => s !== "everything"))("%s names what it omits", (section) => {
    expect(render(section)).toMatch(/ask for `section: "[a-z-]+"`/);
  });
});
