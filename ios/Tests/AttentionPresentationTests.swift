import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// One name and one glyph for the state where a person has to act.
///
/// Both were written out at each site that drew them, and the copies had
/// already diverged: every iOS surface and the tvOS widget cell drew
/// `AttentionBadge`'s person-and-exclamation, while the tvOS status chips drew
/// whatever `statusIcon` the producer had sent. That field means "what this is
/// doing right now", so a chip could read hammer + "Needs you" — a glyph saying
/// `building` beside words saying a human must intervene.
@Suite("Attention presentation")
struct AttentionPresentationTests {
    private func card(status: DashboardStatus, actions: [ActionDefinition]?, statusIcon: String?) -> DashboardCard {
        DashboardCard(
            id: "c",
            template: .summary,
            title: "Card",
            status: status,
            statusIcon: statusIcon,
            actions: actions
        )
    }

    @Test("A card that needs a person says so, whatever glyph its producer sent")
    func cardUnderAttention() {
        let c = card(status: .warning, actions: [ActionDefinition(id: "a", label: "Approve")], statusIcon: "hammer.fill")
        #expect(c.needsUserAttention)
        #expect(c.statusChipLabel == AttentionPresentation.label)
        #expect(c.statusChipSymbolName == AttentionPresentation.symbolName)
    }

    @Test("Otherwise the card keeps its own status and glyph")
    func cardWithoutAttention() {
        let c = card(status: .good, actions: nil, statusIcon: "hammer.fill")
        #expect(!c.needsUserAttention)
        #expect(c.statusChipLabel == DashboardStatus.good.label)
        #expect(c.statusChipSymbolName == "hammer.fill")
    }

    private func activity(items: [LiveActivityItem], statusIcon: String?) -> LiveActivitySession {
        LiveActivitySession(
            externalActivityId: "a",
            title: "Run",
            state: "running",
            statusIcon: statusIcon,
            items: items
        )
    }

    @Test("An activity handing off to its operator does the same")
    func activityUnderAttention() {
        let a = activity(
            items: [LiveActivityItem(id: "i", title: "Approval", status: .warning)],
            statusIcon: "hammer.fill"
        )
        #expect(a.needsUserAttention)
        #expect(a.statusChipLabel == AttentionPresentation.label)
        #expect(a.statusChipSymbolName == AttentionPresentation.symbolName)
    }

    @Test("Otherwise the activity keeps its own state and glyph")
    func activityWithoutAttention() {
        let a = activity(
            items: [LiveActivityItem(id: "i", title: "Build", status: .running)],
            statusIcon: "hammer.fill"
        )
        #expect(!a.needsUserAttention)
        #expect(a.statusChipLabel == "Running")
        #expect(a.statusChipSymbolName == "hammer.fill")
    }
}
