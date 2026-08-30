import Foundation
import Testing
@testable import ZeroZeroWidgetApp

@Suite("Accessibility summaries")
struct AccessibilitySummaryTests {
    @Test("Card surfaces reuse the spoken status report wording")
    func cardSummaryMatchesShortcut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let card = DashboardCard(
            id: "solar",
            template: .progress,
            title: "Solar",
            subtitle: "Roof array",
            value: "3.4",
            unit: "kW",
            status: .good,
            progress: 0.5,
            updatedAt: now
        )

        #expect(CardAccessibilitySummary.summary(for: card, now: now) == CardStatusReport.summary(for: card, now: now))
    }

    @Test("Live Activity summary leads with primary state")
    func liveActivitySummary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = LiveActivitySession(
            externalActivityId: "washer",
            kind: .appliance,
            title: "Washer",
            subtitle: "Rinse cycle",
            state: "running",
            signal: .caution,
            value: "18",
            unit: "min",
            progress: 0.42,
            updatedAt: now,
            staleAt: now.addingTimeInterval(600)
        )

        #expect(LiveActivityAccessibilitySummary.summary(for: session) == "Washer, 18 min, caution, 42% complete, Rinse cycle")
    }

    @Test("Activity item summary combines value, progress, and context")
    func activityItemSummary() {
        let item = LiveActivityItem(
            id: "rinse",
            title: "Rinse",
            subtitle: "Cold water",
            value: "4",
            unit: "min",
            progress: 0.25,
            status: .running
        )

        #expect(LiveActivityAccessibilitySummary.summary(for: item) == "Rinse, 4 min, 25% complete, Cold water")
    }
}

@Suite("Card accessibility detail")
struct CardAccessibilityDetailTests {
    private func card(
        template: DashboardTemplate,
        items: [DashboardItem]? = nil,
        chart: DashboardChart? = nil
    ) -> DashboardCard {
        DashboardCard(
            id: "card",
            template: template,
            title: "Card",
            status: .good,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            items: items,
            chart: chart
        )
    }

    @Test("A list card speaks the rows the surface draws, and no more")
    func listRowsAreLimited() {
        let items = (1...5).map {
            DashboardItem(id: "\($0)", title: "Child \($0)", value: "\($0)", unit: "€")
        }
        let detail = CardAccessibilitySummary.detail(for: card(template: .list, items: items), rowLimit: 3)

        #expect(detail == "Child 1 1 €. Child 2 2 €. Child 3 3 €.")
    }

    @Test("A list row with no value falls back to its status")
    func listRowFallsBackToStatus() {
        let items = [DashboardItem(id: "1", title: "Backups", status: .critical)]
        let detail = CardAccessibilitySummary.detail(for: card(template: .list, items: items), rowLimit: 3)

        #expect(detail == "Backups Critical.")
    }

    @Test("History and breakdown reuse their plot's own wording")
    func plotsReuseTheirDescriptions() {
        let items = (1...3).map { DashboardItem(id: "\($0)", title: "Run \($0)", status: .good, amount: 1) }

        #expect(
            CardAccessibilitySummary.detail(for: card(template: .history, items: items), rowLimit: 14)
                == StatusStripView.accessibilityDescription(for: items) + "."
        )
        #expect(
            CardAccessibilitySummary.detail(for: card(template: .breakdown, items: items), rowLimit: 3)
                == CompositionBarView.accessibilityDescription(for: items) + "."
        )
    }

    @Test("A history card keeps only the pips it draws")
    func historyKeepsTheDrawnPips() {
        let items = (1...20).map { DashboardItem(id: "\($0)", title: "Run \($0)", status: .good) }
        let detail = CardAccessibilitySummary.detail(for: card(template: .history, items: items), rowLimit: 14)

        #expect(detail == "Last 14: 14 good.")
    }

    @Test("A card with no plot has no detail to add")
    func summaryOnlyCardsAreEmpty() {
        #expect(CardAccessibilitySummary.detail(for: card(template: .summary), rowLimit: 3).isEmpty)
    }

    @Test("A briefing speaks only the ordered details the surface draws")
    func briefingSectionsAreLimited() {
        let briefing = DashboardBriefing(sections: [
            DashboardBriefingSection(id: "cause", label: "Cause", text: "Approval is pending"),
            DashboardBriefingSection(id: "impact", label: "Impact", text: "Refunds are delayed"),
            DashboardBriefingSection(id: "next", label: "Next", text: "Approve the migration"),
        ])
        let briefingCard = DashboardCard(
            id: "release",
            template: .briefing,
            title: "Release",
            briefing: briefing
        )

        #expect(
            CardAccessibilitySummary.detail(for: briefingCard, rowLimit: 2)
                == "Cause: Approval is pending. Impact: Refunds are delayed."
        )
    }

    @Test("A chart is described wherever one is renderable")
    func chartIsAlwaysDescribed() {
        let chart = DashboardChart(points: [1, 2, 3])
        let detail = CardAccessibilitySummary.detail(for: card(template: .chart, chart: chart), rowLimit: 3)

        #expect(detail == chart.accessibilityDescription + ".")
    }
}
