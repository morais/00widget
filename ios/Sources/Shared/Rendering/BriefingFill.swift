import CoreGraphics

/// How many `briefing` sections a canvas shows, and how many lines each gets.
///
/// The list and legend stacks measure a row count because their rows are
/// uniform: one line, one height, so `height / unit` is an answer. A briefing
/// section is a label above a paragraph of producer-supplied prose, so the
/// useful variable is not only how many sections to show but how much of each
/// to let through — and the two trade against each other. The counts used to be
/// constants (three sections, two lines each, on every large canvas), which
/// truncated prose on a card with room for all of it.
///
/// `lines` bounds each section's height, so the total this computes is an upper
/// bound: a section with less text than its allowance takes less room, and the
/// plan never overflows. Sections come ordered most important first, so when
/// not all of them fit the tail is what goes.
public enum BriefingFill {
    public struct Plan: Equatable {
        public let sections: Int
        public let lines: Int
    }

    public static func plan(
        height: CGFloat,
        sectionCount: Int,
        lineHeight: CGFloat,
        labelHeight: CGFloat,
        spacing: CGFloat,
        maxLines: Int = 5,
        minLines: Int = 2
    ) -> Plan {
        guard sectionCount > 0, height > 0, lineHeight > 0 else {
            return Plan(sections: 0, lines: minLines)
        }
        func fits(_ count: Int, _ lines: Int) -> Bool {
            let each = labelHeight + CGFloat(lines) * lineHeight
            return CGFloat(count) * each + CGFloat(max(0, count - 1)) * spacing <= height
        }
        // Showing every section beats showing more of a few: the sections a
        // producer sent are its own summary, and dropping one loses a point
        // where a shorter one only loses a clause.
        for lines in stride(from: maxLines, through: minLines, by: -1) where fits(sectionCount, lines) {
            return Plan(sections: sectionCount, lines: lines)
        }
        var count = sectionCount
        while count > 1 && !fits(count, minLines) { count -= 1 }
        return Plan(sections: count, lines: minLines)
    }
}
