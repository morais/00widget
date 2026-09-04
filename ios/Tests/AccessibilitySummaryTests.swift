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

    @Test("Card attribution is included in the spoken summary")
    func cardProducer() {
        let card = DashboardCard(
            id: "trials",
            template: .summary,
            title: "Trials",
            value: "128",
            status: .good,
            producer: CardProducer(label: "Growth Agent", icon: "chart.line.uptrend.xyaxis")
        )

        #expect(CardAccessibilitySummary.summary(for: card).contains("From Growth Agent."))
    }

    @Test("Attribution is not spoken twice when the subtitle already opens with it")
    func cardProducerRepeatingSubtitle() {
        let card = DashboardCard(
            id: "trials",
            template: .summary,
            title: "Trials",
            subtitle: "Growth Agent · up 18 this week",
            value: "128",
            status: .good,
            producer: CardProducer(label: "Growth Agent")
        )

        let spoken = CardAccessibilitySummary.summary(for: card)
        // The subtitle still carries the name; only the second copy goes.
        #expect(spoken.contains("Growth Agent · up 18 this week."))
        #expect(!spoken.contains("From Growth Agent."))
    }

    @Test("A producer the subtitle does not open with is still spoken")
    func cardProducerDistinctFromSubtitle() {
        let card = DashboardCard(
            id: "spend",
            template: .summary,
            title: "Spend",
            subtitle: "of $30 today · $11.60 left",
            value: "$18.40",
            status: .good,
            producer: CardProducer(label: "Usage Agent")
        )

        #expect(CardAccessibilitySummary.summary(for: card).contains("From Usage Agent."))
    }

    @Test("Typed comparison carries its interpretation into the spoken summary")
    func cardComparison() {
        let card = DashboardCard(
            id: "trials",
            template: .chart,
            title: "Trials",
            value: "128",
            unit: "today",
            status: .good,
            comparison: CardComparison(value: "+18", label: "vs Monday", signal: .favorable)
        )

        #expect(CardAccessibilitySummary.summary(for: card).contains("+18 vs Monday, favorable."))
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
            status: .running,
            semantic: MetricSemantic(role: .actual, flow: .inbound)
        )

        #expect(LiveActivityAccessibilitySummary.summary(for: item) == "Rinse, 4 min, actual, inbound, 25% complete, Cold water")
    }

    @Test("A four-of-five activity counts only its unfinished decision as active")
    func fourOfFiveActivitySummary() {
        let session = launchSession(
            value: "4/5",
            progress: 0.8,
            items: [
                LiveActivityItem(id: "announcement", title: "Announcement", status: .warning),
                LiveActivityItem(id: "store", title: "Store", status: .finished),
                LiveActivityItem(id: "website", title: "Website", status: .finished),
                LiveActivityItem(id: "tests", title: "Tests", status: .finished),
                LiveActivityItem(id: "build", title: "Build", status: .finished),
            ]
        )

        #expect(
            LiveActivityAccessibilitySummary.summary(for: session)
                == "App launch, 4/5, 1 active, 80% complete"
        )
    }

    @Test("An all-finished activity reports completion without an active-work count")
    func allFinishedActivitySummary() {
        let session = launchSession(
            value: "5/5",
            progress: 1,
            items: (1...5).map {
                LiveActivityItem(id: "step-\($0)", title: "Step \($0)", status: .finished)
            }
        )

        let summary = LiveActivityAccessibilitySummary.summary(for: session)
        #expect(summary == "App launch, 5/5, 100% complete")
        #expect(!summary.contains("active"))
    }

    private func launchSession(
        value: String,
        progress: Double,
        items: [LiveActivityItem]
    ) -> LiveActivitySession {
        LiveActivitySession(
            externalActivityId: "launch",
            kind: .job,
            title: "App launch",
            state: "running",
            value: value,
            progress: progress,
            items: items,
            updatedAt: Date()
        )
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
