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
            value: "18",
            unit: "min",
            progress: 0.42,
            updatedAt: now,
            staleAt: now.addingTimeInterval(600)
        )

        #expect(LiveActivityAccessibilitySummary.summary(for: session) == "Washer, 18 min, 42% complete, Rinse cycle")
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
