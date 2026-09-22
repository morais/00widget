import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// A briefing's sections used to be a constant count at a constant line limit
/// — three sections of two lines on every large canvas — so a card with room
/// for all of its prose truncated it anyway. Raising the line limit only moved
/// the fault: an allowance divided evenly has to assume every section is as
/// long as every other, so a short one is paid for at the full rate and the
/// long one under it truncates with the canvas half empty. The line count is
/// now the stack's to divide; what is planned here is the seat count.
@Suite("Briefing fill")
struct BriefingFillTests {
    private let line: CGFloat = 16
    private let label: CGFloat = 15
    private let indicator: CGFloat = 14

    private func fit(height: CGFloat, sections: Int, ceiling: Int = 8) -> BriefingFill.Fit {
        BriefingFill.fit(
            height: height, sectionCount: sections,
            lineHeight: line, labelHeight: label, spacing: 5,
            ceiling: ceiling, indicatorHeight: indicator
        )
    }

    @Test("A taller canvas seats more sections")
    func heightBuysSections() {
        #expect(fit(height: 160, sections: 6).sections < fit(height: 400, sections: 6).sections)
    }

    @Test("Every section it can seat, it seats")
    func seatsWhatFits() {
        // Room for four sections of two lines each.
        let p = fit(height: 220, sections: 4)
        #expect(p.sections == 4)
        #expect(p.hidden == 0)
    }

    @Test("When not all of them fit, the tail goes")
    func dropsTheTail() {
        let p = fit(height: 100, sections: 6)
        #expect(p.sections < 6)
        #expect(p.sections >= 1)
        #expect(p.hidden == 6 - p.sections)
    }

    @Test("What is hidden is counted against the whole card, not the ceiling")
    func hiddenCountsEverySection() {
        // Eight sections on a canvas that seats three, behind a ceiling of
        // four. Five are missing; the line used to say nothing at all,
        // because it compared the seats against the ceiling rather than
        // against what the producer sent.
        let p = fit(height: 160, sections: 8, ceiling: 4)
        #expect(p.sections >= 1)
        #expect(p.hidden == 8 - p.sections)
    }

    @Test("Hiding one is not worth a line to announce")
    func oneHiddenIsSilent() {
        let seats = BriefingFill.capacity(
            height: 200, lineHeight: line, labelHeight: label, spacing: 5
        )
        let p = fit(height: 200, sections: seats + 1)
        #expect(p.sections == seats)
        #expect(p.hidden == 0)
    }

    @Test("The line it spends saying so comes out of its own room")
    func indicatorPaysItsWay() {
        for height in stride(from: 60.0, through: 600.0, by: 10.0) {
            for count in 1...10 {
                let p = fit(height: height, sections: count)
                let each = label + 2 * line
                let drawn = CGFloat(p.sections) * each
                    + CGFloat(Swift.max(0, p.sections - 1)) * 5
                    + (p.hidden > 0 ? indicator + 5 : 0)
                // One section is drawn even where it cannot fit, which is the
                // one case a card is allowed to clip rather than say nothing.
                #expect(p.sections == 1 || drawn <= height)
            }
        }
    }

    @Test("Nothing to plan")
    func empty() {
        #expect(fit(height: 200, sections: 0).sections == 0)
        #expect(fit(height: 0, sections: 3).sections == 0)
    }
}
