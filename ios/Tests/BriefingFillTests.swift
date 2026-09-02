import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// A briefing's sections used to be a constant count at a constant line limit
/// — three sections of two lines on every large canvas — so a card with room
/// for all of its prose truncated it anyway.
@Suite("Briefing fill")
struct BriefingFillTests {
    private let line: CGFloat = 16
    private let label: CGFloat = 15

    private func plan(height: CGFloat, sections: Int) -> BriefingFill.Plan {
        BriefingFill.plan(
            height: height, sectionCount: sections,
            lineHeight: line, labelHeight: label, spacing: 5
        )
    }

    @Test("Room to spare is spent on more of each section")
    func slackBuysLines() {
        // Three sections in a large widget's lower half: every one of them,
        // with several lines each rather than two.
        let generous = plan(height: 300, sections: 3)
        #expect(generous.sections == 3)
        #expect(generous.lines > 2)
        // The same three in half the room: still all three, fewer lines.
        let tight = plan(height: 160, sections: 3)
        #expect(tight.sections == 3)
        #expect(tight.lines < generous.lines)
    }

    @Test("Showing every section beats showing more of a few")
    func sectionsOutrankLines() {
        // Room for four sections of two lines, or three of three. It takes
        // the four: a dropped section loses a point, a dropped line a clause.
        let p = plan(height: 220, sections: 4)
        #expect(p.sections == 4)
        #expect(p.lines == 2)
    }

    @Test("When not all of them fit, the tail goes")
    func dropsTheTail() {
        let p = plan(height: 100, sections: 6)
        #expect(p.sections < 6)
        #expect(p.sections >= 1)
        #expect(p.lines == 2)
    }

    @Test("A plan never asks for more room than it was given")
    func planFits() {
        for height in stride(from: 60.0, through: 400.0, by: 20.0) {
            for count in 1...8 {
                let p = plan(height: height, sections: count)
                let each = label + CGFloat(p.lines) * line
                let total = CGFloat(p.sections) * each + CGFloat(p.sections - 1) * 5
                // One section is drawn even where it cannot fit, which is the
                // one case a card is allowed to clip rather than say nothing.
                #expect(p.sections == 1 || total <= height)
            }
        }
    }

    @Test("Nothing to plan")
    func empty() {
        #expect(plan(height: 200, sections: 0).sections == 0)
        #expect(plan(height: 0, sections: 3).sections == 0)
    }
}
