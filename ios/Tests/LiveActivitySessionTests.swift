import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// `staleAt` is what makes a producer that has gone quiet visible to the
/// operator, and on the Lock Screen ActivityKit enforces it. The Apple TV
/// dashboard draws sessions fetched from the API instead, where nothing
/// enforces anything — a wall-mounted television is the one place an activity
/// can present hours-old numbers as current all evening.
@Suite("Live Activity staleness")
struct LiveActivitySessionTests {

    @Test("A session past its staleAt is stale, one short of it is not")
    func staleAtDecides() {
        #expect(session(staleAt: Date().addingTimeInterval(-1)).isStale)
        #expect(!session(staleAt: Date().addingTimeInterval(60)).isStale)
    }

    /// A producer may send no `staleAt` at all, which must not read as "fresh
    /// forever". The hour matches `DashboardCard.isStale` so the two surfaces
    /// of the same dashboard age at the same rate.
    @Test("Without staleAt, an hour since the last update is the fallback")
    func fallbackIsAnHourSinceUpdate() {
        #expect(session(updatedAt: Date().addingTimeInterval(-3_601)).isStale)
        #expect(!session(updatedAt: Date().addingTimeInterval(-3_599)).isStale)
    }

    /// An explicit `staleAt` outranks the fallback in both directions: a
    /// producer publishing every few seconds may still declare itself stale
    /// quickly, and one that publishes hourly may declare a longer life.
    @Test("An explicit staleAt outranks the fallback in both directions")
    func staleAtOutranksFallback() {
        #expect(
            session(
                updatedAt: Date().addingTimeInterval(-10),
                staleAt: Date().addingTimeInterval(-5)
            ).isStale
        )
        #expect(
            !session(
                updatedAt: Date().addingTimeInterval(-7_200),
                staleAt: Date().addingTimeInterval(3_600)
            ).isStale
        )
    }

    private func session(
        updatedAt: Date = Date(),
        staleAt: Date? = nil
    ) -> LiveActivitySession {
        LiveActivitySession(
            externalActivityId: "act-1",
            title: "Deploy",
            state: "running",
            updatedAt: updatedAt,
            staleAt: staleAt
        )
    }
}
