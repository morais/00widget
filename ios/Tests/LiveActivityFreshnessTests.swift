import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// The two facts a Live Activity has to keep telling the truth about once its
/// producer stops sending: how old the reading is, and whether the estimate it
/// was counting down to is spent.
///
/// Both used to fail the same way and for the same reason. ActivityKit rebuilds
/// a Live Activity when its content state changes, so a producer that has gone
/// quiet is exactly the case no redraw is coming for — which is why the views
/// that draw these read them inside a `TimelineView`. What is testable here is
/// only the answer, not the redraw; the timelines themselves are checked by
/// looking at a device.
@Suite("Live Activity freshness")
struct LiveActivityFreshnessTests {

    // MARK: Staleness

    @Test("A producer's own staleAt decides, in both directions")
    func explicitStaleAtDecides() {
        let now = Date()
        #expect(state(updatedAt: now, staleAt: now.addingTimeInterval(60)).isStale == false)
        #expect(state(updatedAt: now, staleAt: now.addingTimeInterval(-1)).isStale)
    }

    /// The hour matters more than it looks: a producer that never sent
    /// `staleAt` gets no `stale-date` in the push either, so ActivityKit's own
    /// flag is never set for it and this fallback is the only thing that can
    /// notice. Producers that forget the field are not a rare case — they are
    /// the ones most likely to go quiet.
    @Test("Without staleAt, an hour since the last update is stale")
    func hourFallbackApplies() {
        let now = Date()
        #expect(state(updatedAt: now.addingTimeInterval(-3_599)).isStale == false)
        #expect(state(updatedAt: now.addingTimeInterval(-3_601)).isStale)
    }

    /// `LiveActivitySession` answers this for the Apple TV dashboard and the
    /// in-app list; `ContentState` answers it for the Lock Screen and the
    /// Dynamic Island. Two definitions of one silence is how the surfaces
    /// drift into describing it differently.
    @Test("The session and the content state agree")
    func sessionAndContentStateAgree() {
        let updatedAt = Date().addingTimeInterval(-7_200)
        let session = LiveActivitySession(
            externalActivityId: "job",
            title: "Job",
            state: "running",
            updatedAt: updatedAt
        )
        #expect(session.isStale == state(updatedAt: updatedAt).isStale)
    }

    // MARK: Overdue countdowns

    /// "~0 min" is not a smaller estimate. It is a claim that the job is about
    /// to finish, and it was what a Lock Screen showed for the rest of the day
    /// once an ETA overran.
    @Test("A spent deadline says so instead of parking on zero")
    func overdueCountdownSaysSo() {
        #expect(minutes(seconds: 60) == "~1 min")
        #expect(minutes(seconds: 1) == "~1 min")
        #expect(minutes(seconds: 0) == "Overdue")
        #expect(minutes(seconds: -600) == "Overdue")
    }

    @Test("Minute wording is unchanged either side of the hour")
    func minuteWordingHolds() {
        #expect(minutes(seconds: 2_220) == "~37 min")
        #expect(minutes(seconds: 3_600) == "~1h")
        #expect(minutes(seconds: 5_400) == "~1h 30m")
    }

    // MARK: Helpers

    /// Anchored rather than relative to `Date()`, so a rung decided exactly on
    /// a unit boundary is not landed on a hair either side of it.
    private func minutes(seconds: TimeInterval) -> String {
        LiveActivityCountdownText.minuteText(
            endsAt: Date(timeIntervalSinceReferenceDate: seconds),
            now: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private func state(
        updatedAt: Date,
        staleAt: Date? = nil
    ) -> ZeroZeroWidgetActivityAttributes.ContentState {
        ZeroZeroWidgetActivityAttributes.ContentState(
            state: "running",
            updatedAt: updatedAt,
            staleAt: staleAt
        )
    }
}
