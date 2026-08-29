import SwiftUI

/// When the *producer* last published, which is a different fact from the page
/// header's "Updated" — that one is when this device last synced — and the one
/// that goes wrong quietly. A television is left running on a wall, so an
/// activity whose producer stopped has to say so rather than keep presenting
/// its last numbers as current.
///
/// It says so without saying so. The line used to be rewritten to "Not
/// updating · last update 2 hours ago", which is a sentence a grid of nine
/// cards repeats into a wall of alarm — for something whose remedy is to look
/// at the producer later. What is left is the same line every card already
/// carries, in the warning colour, behind a warning glyph. One view for every
/// surface that draws it, so the card and the detail panel cannot drift into
/// describing the same silence two different ways.
struct TVFreshness: View {
    let updatedAt: Date
    /// Deliberately a closure. `isStale` is a comparison against `Date()`, so
    /// evaluating it once when this view is built would freeze the answer at
    /// the moment of the last redraw — which is the whole bug `TVTickingClock`
    /// exists to fix, in the one place it matters most. Called inside the
    /// timeline, an activity that goes quiet turns orange on its own.
    let isStale: () -> Bool
    let font: Font

    var body: some View {
        TVTickingClock(since: updatedAt) {
            let isStale = self.isStale()
            HStack(spacing: 8) {
                // Not conditional on `accessibilityDifferentiateWithoutColor`.
                // That setting is opt-in and most people who would benefit
                // never turn it on, and with the words gone the colour would
                // otherwise be carrying the whole signal by itself.
                if isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                }
                Text("Updated \(updatedAt.formatted(.relative(presentation: .named)))")
            }
            .font(font)
            // Neither of these is `.tertiary`. This app is always dark, where
            // tertiary is white at 30% and computes to about 2.5:1 — under the
            // 3:1 large-text threshold, let alone 4.5:1. Secondary is 60% and
            // about 7.4:1. Nothing here is decorative enough for tertiary.
            .foregroundStyle(isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .lineLimit(1)
        }
    }
}
