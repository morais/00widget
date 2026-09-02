import { describe, it, expect } from "vitest";
import { liveActivityWarnings } from "../src/liveActivityAdvice";
import { LiveActivitySessionSchema } from "../src/types";

/// Every case here is a request that succeeds. That is the whole point of the
/// mechanism: a Live Activity that renders badly is not an invalid one, so
/// there is no error to raise and nothing in a 200 that tells a producer its
/// title is being truncated on a Lock Screen it cannot see.
///
/// The shape under test is the one an agent actually published while driving
/// the marketing screenshot capture — a 28-character title, prose in
/// `subtitle`, a step counter in `value` and no `progress` — which stored,
/// pushed, and returned 200 on every call.

function session(overrides: Record<string, unknown> = {}) {
  return LiveActivitySessionSchema.parse({
    activityInstanceId: "instance-1",
    externalActivityId: "job-1",
    kind: "job",
    title: "Screenshots",
    state: "running",
    startedAt: "2026-09-02T10:47:00.000Z",
    updatedAt: "2026-09-02T10:47:00.000Z",
    staleAt: "2099-01-01T00:00:00.000Z",
    value: "1/4",
    progress: 0.25,
    ...overrides,
  });
}

const codes = (...args: Parameters<typeof liveActivityWarnings>) =>
  liveActivityWarnings(...args).map((warning) => warning.code);

describe("Live Activity rendering advice", () => {
  it("says nothing about a well-formed activity", () => {
    expect(codes(session(), { isStart: true, staleAtPushed: "2099-01-01T00:00:00.000Z" }))
      .toEqual([]);
  });

  it("flags the request that started this", () => {
    const published = session({
      title: "Marketing screenshot capture",
      subtitle: "iPhone 6.3-inch: UI tests still running (6m 30s); iPad, iPhone 6.5-inch and Apple TV still queued",
      value: "1/4",
      progress: undefined,
      staleAt: undefined,
    });
    expect(codes(published, { isStart: true })).toEqual([
      "title-may-truncate",
      "no-stale-date",
      "subtitle-may-truncate",
      "fraction-without-progress",
    ]);
  });

  /// The one that costs a field and buys a bar on four surfaces.
  it("reads a step counter out of value and asks for progress", () => {
    for (const value of ["1/4", "Capture 1/4", "3 of 8"]) {
      expect(codes(session({ value, progress: undefined }), { isStart: true }))
        .toContain("fraction-without-progress");
    }
  });

  /// Narrow on purpose. A version string or an aspect ratio read as completion
  /// would put a warning on activities that have nothing wrong with them, and
  /// warnings that cry wolf get the whole set ignored.
  it("does not read version strings or dates as fractions", () => {
    for (const value of ["v1.2/beta", "16/9 ratio", "5/0", "9/4", "no digits"]) {
      expect(codes(session({ value, progress: undefined }), { isStart: true }))
        .not.toContain("fraction-without-progress");
    }
    // "9/4" is a fraction with done > total; "3/4" genuinely is one, and being
    // read as three-quarters complete is the documented cost of the heuristic.
    expect(codes(session({ value: "3/4", progress: undefined }), { isStart: true }))
      .toContain("fraction-without-progress");
  });

  it("tells an update that a title it sent will never reach the device", () => {
    expect(codes(session(), { isStart: false, requestedTitle: "New name", staleAtPushed: "2099-01-01T00:00:00.000Z" }))
      .toEqual(["title-is-frozen"]);
    // An update that never mentioned a title must not be told its title is
    // frozen — the merged session always carries one.
    expect(codes(session(), { isStart: false, staleAtPushed: "2099-01-01T00:00:00.000Z" }))
      .toEqual([]);
  });

  /// A stored stale date from an earlier update sets no `aps.stale-date` on
  /// this push, which is the same distinction `staleAtPushed` draws.
  it("asks for a stale date on every push, not just the first", () => {
    expect(codes(session({ staleAt: "2099-01-01T00:00:00.000Z" }), { isStart: false }))
      .toEqual(["no-stale-date-pushed"]);
  });

  it("notices an activity that renders as a bare icon in the minimal circle", () => {
    const bare = session({ value: "Capturing", progress: undefined, endsAt: undefined, items: undefined });
    expect(codes(bare, { isStart: true })).toContain("minimal-island-shows-only-an-icon");

    // Any one rung of the ladder is enough.
    for (const filled of [
      { progress: 0.5 },
      { endsAt: "2099-01-01T00:00:00.000Z" },
      { value: "78%" },
      { items: [{ id: "a", title: "iPhone" }] },
    ]) {
      expect(codes(session({ value: "Capturing", progress: undefined, ...filled }), { isStart: true }))
        .not.toContain("minimal-island-shows-only-an-icon");
    }
  });

  it("flags a deadline that has already passed", () => {
    expect(codes(session({ endsAt: "2020-01-01T00:00:00.000Z" }), { isStart: true }))
      .toContain("ends-at-in-the-past");
    expect(codes(session({ endsAt: "2099-01-01T00:00:00.000Z" }), { isStart: true }))
      .not.toContain("ends-at-in-the-past");
  });

  /// iOS gives the chart up when item rows fill the banner. The request is
  /// valid, this API reports the chart back, and only the surfaces the activity
  /// exists for drop it.
  it("flags a chart that item rows will hide", () => {
    const chart = { points: [1, 2, 3] };
    expect(codes(session({ chart, items: [{ id: "a", title: "iPhone" }] }), { isStart: true }))
      .toContain("chart-hidden-by-items");
    // Items that have all finished are hidden, so the chart reappears and the
    // warning must go with it.
    expect(codes(session({ chart, items: [{ id: "a", title: "iPhone", status: "finished" }] }), { isStart: true }))
      .not.toContain("chart-hidden-by-items");
  });
});
