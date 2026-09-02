import type { LiveActivitySession } from "./types";

/// Advisory notes returned alongside a successful `start` or `update`.
///
/// Everything here is a *rendering* problem, which is the class of mistake this
/// API cannot express as an error. A request that publishes a 28-character
/// title, prose in `subtitle`, and a step counter with no `progress` is
/// completely valid — it stores, it pushes, it returns 200, and the operator
/// gets a Lock Screen where the number is truncated and the progress bar is
/// missing. The producer has no way to see that: it is not holding the phone.
///
/// So the warnings go where a producer is already looking, on the response to
/// the call it just made, rather than waiting to be asked for by a `get_status`
/// the agent has no reason to suspect it needs. They never change the outcome
/// of the request and are never an error; an agent that ignores them is exactly
/// as correct as before.
export interface LiveActivityWarning {
  code: string;
  field?: string;
  message: string;
}

/// The character counts below are budgets for a *surface*, not for the
/// transport — the size table in `docs/llms.md` gives `title` 120 characters
/// and means it, in the sense that 120 will be stored and delivered intact.
/// Roughly a third of a Dynamic Island is what actually draws it.
///
/// Deliberately generous, and each one describes the effect rather than
/// asserting a cutoff: they are read off type sizes and region widths rather
/// than measured on a device, and a warning that cries wolf at 17 characters
/// gets every warning in this file ignored.
const Budgets = {
  /// The expanded island's leading region is about a third of the width, less
  /// the Label's own glyph, at `.caption`. Past this it scales down and then
  /// truncates. `title` is an ActivityAttribute, so unlike everything else here
  /// it cannot be corrected without restarting the activity.
  title: 24,
  /// Two lines of the expanded island's bottom region at `.caption`. The Lock
  /// Screen has slightly less, being inset past the icon column.
  subtitle: 80,
  /// The Dynamic Island's minimal circle, about 24pt across — three glyphs,
  /// mirroring `minimalValueToken` in the app.
  minimalValue: 3,
} as const;

/// A step counter written into `value` — "1/4", "Capture 1/4", "3 of 8".
///
/// Mirrors `LiveActivityValueFraction` in the app, which reads the same strings
/// to draw the minimal circle's ring. It is deliberately narrow for the reason
/// stated there: anything looser starts reading version strings and aspect
/// ratios as completion. The two are not kept in lockstep by anything, and do
/// not need to be — drift here costs at most one unemitted or one surplus
/// warning, never a wrong render.
function looksLikeAFraction(text: string): boolean {
  const parts = text.replace(/ of /i, "/").split("/");
  if (parts.length !== 2) return false;
  const done = /(^|\s)(\d{1,6})$/.exec(parts[0].trim());
  const total = /^(\d{1,6})(\s|$)/.exec(parts[1].trim());
  if (!done || !total) return false;
  const totalValue = Number(total[1]);
  return totalValue > 0 && Number(done[2]) <= totalValue;
}

export interface AdviceOptions {
  /// A start can still choose its title; an update cannot change the one the
  /// device is drawing, so the two need different advice about the same field.
  isStart: boolean;
  /// The title this request asked for, when it named one at all. Only an update
  /// distinguishes "did not mention it" from "sent the same string".
  requestedTitle?: string;
  /// The stale date *this push carried*, which is the only one that reaches
  /// `aps.stale-date`. A stored value from an earlier update does not cover
  /// this one — see `staleAtPushed` on the update response.
  staleAtPushed?: string;
}

export function liveActivityWarnings(
  session: LiveActivitySession,
  options: AdviceOptions,
): LiveActivityWarning[] {
  const warnings: LiveActivityWarning[] = [];
  const now = Date.now();

  if (options.isStart) {
    if (session.title.length > Budgets.title) {
      warnings.push({
        code: "title-may-truncate",
        field: "title",
        message:
          `title is ${session.title.length} characters; the Dynamic Island's expanded ` +
          `leading region draws roughly ${Budgets.title} before it shrinks and then ` +
          `truncates. It is an ActivityAttribute, frozen for the life of the activity, ` +
          `so this cannot be corrected by an update — only by starting again. Name the ` +
          `thing, not what it is doing: "Screenshots", not "Marketing screenshot capture".`,
      });
    }
    if (!session.staleAt) {
      warnings.push({
        code: "no-stale-date",
        field: "staleAt",
        message:
          "no staleAt, so nothing will ever mark this activity out of date. If this " +
          "producer stops, the Lock Screen keeps presenting its last state as current. " +
          "Send staleAt on every push, a little beyond your next expected update.",
      });
    }
  } else {
    // An update may carry `title`; the device will never see it. The stored row
    // and `GET /v1/live-activities` will, which is the trap — the producer
    // reads back what it sent and concludes the change landed.
    if (options.requestedTitle !== undefined) {
      warnings.push({
        code: "title-is-frozen",
        field: "title",
        message:
          "title is an ActivityAttribute, fixed when the activity started. This update " +
          "changes the stored record and what this API reports back, but the Lock Screen " +
          "and Dynamic Island keep the original. Put anything that moves in value, " +
          "progress, subtitle, items or endsAt; to genuinely rename, start again with " +
          "the same externalActivityId.",
      });
    }
    if (!options.staleAtPushed) {
      warnings.push({
        code: "no-stale-date-pushed",
        field: "staleAt",
        message:
          "this push carried no staleAt, so it set no aps.stale-date on the device — a " +
          "value from an earlier update does not cover this state. Send staleAt on " +
          "every push.",
      });
    }
  }

  if (session.subtitle && session.subtitle.length > Budgets.subtitle) {
    warnings.push({
      code: "subtitle-may-truncate",
      field: "subtitle",
      message:
        `subtitle is ${session.subtitle.length} characters; it wraps to two lines and ` +
        `truncates past roughly ${Budgets.subtitle} on the Lock Screen and in the ` +
        `expanded Dynamic Island, and the compact regions never draw it at all. It is a ` +
        `label rather than a sentence — put per-part detail in items instead.`,
    });
  }

  // The one that cost the most here. A producer counting "1/4" in prose has a
  // fraction and has not sent it as one, so every surface that draws a bar or a
  // ring — Lock Screen, expanded island, Watch, and the minimal circle when the
  // activity has no deadline — falls back to something less informative or to
  // nothing. It costs one field.
  if (session.progress === undefined && session.value && looksLikeAFraction(session.value)) {
    warnings.push({
      code: "fraction-without-progress",
      field: "progress",
      message:
        `value ${JSON.stringify(session.value)} reads as a fraction but no progress was ` +
        "sent. Send progress as 0.0-1.0 alongside it: it is what draws the Lock Screen " +
        "bar, the expanded island's bar, and the Apple Watch gauge, none of which can " +
        "derive it from a string.",
    });
  }

  // The rungs `MinimalIslandView` reads, in its order. A second Live Activity
  // anywhere on the device — Screen Recording counts — collapses this one to a
  // single circle in place of both compact regions, and there is no API to
  // decline it. An activity with nothing on the ladder draws only its glyph.
  const hasMinimalToken = session.value !== undefined
    && session.value.trim().length > 0
    && session.value.trim().length <= Budgets.minimalValue;
  if (
    !session.endsAt
    && session.progress === undefined
    && (session.items ?? []).length === 0
    && !hasMinimalToken
  ) {
    warnings.push({
      code: "minimal-island-shows-only-an-icon",
      message:
        "with no endsAt, progress, items, or a value of " +
        `${Budgets.minimalValue} characters or fewer, this activity renders as a bare ` +
        "icon in the Dynamic Island's minimal circle — which is what the system shows " +
        "whenever a second Live Activity is running, including a screen recording. " +
        "Any one of those fields fills it.",
    });
  }

  if (session.endsAt) {
    const endsAt = Date.parse(session.endsAt);
    if (Number.isFinite(endsAt) && endsAt <= now) {
      warnings.push({
        code: "ends-at-in-the-past",
        field: "endsAt",
        message:
          "endsAt has already passed, so every countdown on this activity reads " +
          "\"Overdue\". Extend it if the work is still running, or end the activity.",
      });
    }
  }

  // `items` and `chart` compete for one banner and iOS gives the chart up. The
  // request is valid, this API reports the chart back, and the app's Activities
  // tab draws it — only the surfaces the activity exists for drop it, which is
  // why it is normally found on a device, late.
  if (session.chart && (session.items ?? []).some((item) => item.status !== "finished" && item.status !== "offline")) {
    warnings.push({
      code: "chart-hidden-by-items",
      field: "chart",
      message:
        "items and chart were both sent. Item rows fill the Lock Screen banner and the " +
        "expanded Dynamic Island, so the chart is not drawn on either; the Apple Watch " +
        "never draws one. Pick one per activity.",
    });
  }

  return warnings;
}
