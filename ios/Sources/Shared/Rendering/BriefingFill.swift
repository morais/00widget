import CoreGraphics

/// How many `briefing` sections a canvas shows.
///
/// A list's rows are uniform — one line, one height — so `height / unit` is an
/// answer, and `ListRowFill` gives it. A briefing section is a label above a
/// paragraph of producer-supplied prose, so how much room each one *wants* is a
/// property of the text rather than of the canvas, and no arithmetic here can
/// know it. What this decides is therefore only the count: how many sections a
/// canvas can seat while guaranteeing each of them at least `minLines`.
///
/// Dividing the rest is the stack's job, not this one's. A filling briefing
/// draws its sections with no line limit inside a frame of exactly the height
/// measured here, so SwiftUI gives each paragraph its ideal height where it
/// fits and truncates only what is left over — a short section takes what it
/// needs and a long one inherits the remainder. A per-section line allowance
/// computed here cannot do that, because it has to assume every section is as
/// long as every other: a three-line section was charged for six, and the
/// paragraph under it truncated with a third of the canvas blank beneath.
///
/// Sections come ordered most important first, so when not all of them fit the
/// tail is what goes.
public enum BriefingFill {
    /// What a filling stack draws: how many sections, and how many are left out
    /// once it has spent a line saying so. The rule for that line is
    /// `ListRowFill`'s — hiding exactly one is not worth a line to announce.
    public struct Fit: Equatable {
        public let sections: Int
        /// Zero when nothing is hidden, or when saying so is not worth a line.
        public let hidden: Int
    }

    /// How many sections of `minLines` lines each fit in `height`, never fewer
    /// than one: a canvas too short for even one section shows it and lets it
    /// clip, which is still more than showing nothing.
    public static func capacity(
        height: CGFloat,
        lineHeight: CGFloat,
        labelHeight: CGFloat,
        spacing: CGFloat,
        minLines: Int = 2
    ) -> Int {
        let each = labelHeight + CGFloat(minLines) * lineHeight
        guard each > 0 else { return 1 }
        return max(1, Int((height + spacing) / (each + spacing)))
    }

    public static func fit(
        height: CGFloat,
        sectionCount: Int,
        lineHeight: CGFloat,
        labelHeight: CGFloat,
        spacing: CGFloat,
        ceiling: Int,
        indicatorHeight: CGFloat,
        minLines: Int = 2
    ) -> Fit {
        guard sectionCount > 0, ceiling > 0, height > 0, lineHeight > 0 else {
            return Fit(sections: 0, hidden: 0)
        }
        func seats(in height: CGFloat) -> Int {
            min(
                sectionCount,
                ceiling,
                capacity(
                    height: height,
                    lineHeight: lineHeight,
                    labelHeight: labelHeight,
                    spacing: spacing,
                    minLines: minLines
                )
            )
        }
        let shown = seats(in: height)
        guard sectionCount - shown >= 2 else { return Fit(sections: shown, hidden: 0) }
        // The line costs its own height and the gap above it.
        let sections = max(1, seats(in: height - indicatorHeight - spacing))
        return Fit(sections: sections, hidden: sectionCount - sections)
    }
}
