import SwiftUI

/// When the *producer* last published — a different fact from a page header's
/// "Updated", which is when this device last synced, and the one that goes
/// wrong quietly.
///
/// It says so without saying so. The line used to be rewritten to "Not
/// updating · last update 2 hours ago", which is a sentence a grid of nine
/// cards repeats into a wall of alarm — for something whose remedy is to look
/// at the producer later. What is left is the same line the surface already
/// carries, in the warning colour, behind a warning glyph.
///
/// One view for every surface that draws it. The Apple TV dashboard and the
/// Lock Screen Live Activity have the same problem for the same reason — both
/// are redrawn only when something arrives, so both need a clock to notice
/// that nothing has — and they must not drift into describing the same silence
/// two different ways.
struct FreshnessLine: View {
    let updatedAt: Date
    /// Deliberately a closure. `isStale` is a comparison against `Date()`, so
    /// evaluating it once when this view is built would freeze the answer at
    /// the moment of the last redraw — which is the whole bug
    /// `RelativeTimeClock` exists to fix, in the one place it matters most.
    /// Called inside the timeline, an activity that goes quiet turns orange on
    /// its own.
    let isStale: () -> Bool
    let font: Font
    var spacing: CGFloat = 8
    /// A Live Activity is drawn by the system out of process, where the clock
    /// below is not driven — see `TimeTicking`. This shipped wrapped in one
    /// regardless, and the line stood still at "Updated 9 seconds ago" on the
    /// Lock Screen, which is the exact failure the whole view exists to
    /// prevent, wearing the costume of the fix.
    var ticking: TimeTicking = .clock

    var body: some View {
        switch ticking {
        case .clock:
            RelativeTimeClock(since: updatedAt) { line(isStale: isStale()) }
        case .systemText:
            // No timeline, and `Text`'s own `DateStyle` rather than the
            // `.relative` FormatStyle: the style is what the system animates,
            // and it is the only thing on this surface that counts up on its
            // own. It renders no "ago" of its own, hence the wording around it.
            //
            // `isStale` is read when the system renders, so the hour-long
            // fallback only lands on whatever redraw happens. The exact answer
            // comes from ActivityKit's own `staleDate`, which does provoke one —
            // one more reason for a producer to send `staleAt`.
            line(
                isStale: isStale(),
                time: Text("Updated \(updatedAt, style: .relative) ago")
            )
        }
    }

    private func line(isStale: Bool, time: Text? = nil) -> some View {
        HStack(spacing: spacing) {
            // Not conditional on `accessibilityDifferentiateWithoutColor`.
            // That setting is opt-in and most people who would benefit
            // never turn it on, and with the words gone the colour would
            // otherwise be carrying the whole signal by itself.
            if isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
            }
            // In-process the wording is free, because the clock above is
            // what makes it move: `.relative(presentation: .named)` reads
            // "Updated 1 minute ago" where `Text(_, style: .relative)`
            // renders "1 min, 9 secs" and no "ago" at all — which reads as
            // how long the job has been running rather than how old the
            // reading is. The widget surfaces pay that wording for a line
            // that actually ticks, and get "ago" back from the sentence
            // around it.
            time ?? Text("Updated \(updatedAt.formatted(.relative(presentation: .named)))")
        }
        .font(font)
        // Neither of these is `.tertiary`. On the dark grounds these draw
        // against, tertiary is white at 30% and computes to about 2.5:1 —
        // under the 3:1 large-text threshold, let alone 4.5:1. Secondary
        // is 60% and about 7.4:1. Nothing here is decorative enough for
        // tertiary.
        .foregroundStyle(isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }
}
