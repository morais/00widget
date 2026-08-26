import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// The Dynamic Island's minimal circle is what a Live Activity is reduced to
/// as soon as a second one — anyone's — is running, and nothing about it can
/// be seen from a screenshot of the app or from a green build. These cover the
/// two halves the ladder in `MinimalIslandView` reads: which fraction is
/// honest enough to draw a ring from, and what a countdown says in three
/// characters.
@Suite("Live Activity minimal presentation")
struct LiveActivityMinimalPresentationTests {

    // MARK: Progress

    @Test("An explicit progress wins and is clamped")
    func explicitProgressWins() {
        #expect(state(progress: 0.4).minimalProgress == 0.4)
        #expect(state(progress: 1.8).minimalProgress == 1)
        #expect(state(progress: -0.2).minimalProgress == 0)
    }

    /// A ring stuck at zero says "nothing has happened" about an activity that
    /// may be halfway through, so a set of items with none finished and no
    /// progress of their own must fall through rather than derive a zero.
    @Test("Items derive a fraction only when they have finished one or all carry progress")
    func itemsDeriveProgress() {
        #expect(state(items: [item(), item(status: .finished)]).minimalProgress == 0.5)
        #expect(state(items: [item(), item()]).minimalProgress == nil)
        #expect(state(items: [item(progress: 0.25), item(progress: 0.75)]).minimalProgress == 0.5)
        #expect(state(items: [item(progress: 0.2), item()]).minimalProgress == nil)
        #expect(state(items: []).minimalProgress == nil)
    }

    @Test("A counter written into value is read as a fraction")
    func valueFractionIsRead() {
        #expect(state(value: "1/4").minimalProgress == 0.25)
        #expect(state(value: "Capture 1/4").minimalProgress == 0.25)
        #expect(state(value: "3 of 8").minimalProgress == 0.375)
        #expect(state(value: "step 2 / 2 done").minimalProgress == 1)
    }

    /// Loose parsing here would put a ring on anything containing a slash. The
    /// digits have to sit against the separator, the denominator has to be the
    /// larger one, and a version string is not a step counter.
    @Test("Anything but a whole-number counter is refused")
    func valueFractionIsNarrow() {
        #expect(LiveActivityValueFraction.value(in: "v1.2/4") == nil)
        #expect(LiveActivityValueFraction.value(in: "16/9") == nil)
        #expect(LiveActivityValueFraction.value(in: "1/0") == nil)
        #expect(LiveActivityValueFraction.value(in: "78%") == nil)
        #expect(LiveActivityValueFraction.value(in: "1/2/3") == nil)
        #expect(LiveActivityValueFraction.value(in: "a/b") == nil)
        #expect(LiveActivityValueFraction.value(in: "1.5/4") == nil)
    }

    @Test("An explicit progress outranks a counter in the value")
    func progressOutranksValue() {
        #expect(state(value: "1/4", progress: 0.9).minimalProgress == 0.9)
    }

    // MARK: Value token

    @Test("Only a value that fits the circle becomes a token")
    func valueTokenFits() {
        #expect(state(value: "1/4").minimalValueToken == "1/4")
        #expect(state(value: " 78% ").minimalValueToken == "78%")
        #expect(state(value: "Capture 1/4").minimalValueToken == nil)
        #expect(state(value: "").minimalValueToken == nil)
        #expect(state().minimalValueToken == nil)
    }

    // MARK: Countdown token

    @Test("A countdown reads as one unit, rounded so it never overstates")
    func countdownToken() {
        #expect(token(seconds: 45) == "45s")
        #expect(token(seconds: 59.4) == "1m")
        #expect(token(seconds: 60) == "1m")
        #expect(token(seconds: 61) == "2m")
        #expect(token(seconds: 3_599) == "1h")
        #expect(token(seconds: 3_600) == "1h")
        #expect(token(seconds: 7_200) == "2h")
        #expect(token(seconds: 86_399) == "1d")
        #expect(token(seconds: 172_800) == "2d")
        #expect(token(seconds: 0) == "0m")
        #expect(token(seconds: -30) == "0m")
    }

    // MARK: Helpers

    /// Anchored rather than relative to `Date()`: adding an interval and
    /// subtracting it back can land a hair either side of a unit boundary, and
    /// every rung of `tokenText` is decided exactly on one.
    private func token(seconds: TimeInterval) -> String {
        LiveActivityCountdownToken.tokenText(
            endsAt: Date(timeIntervalSinceReferenceDate: seconds),
            now: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private func state(
        value: String? = nil,
        progress: Double? = nil,
        items: [LiveActivityItem]? = nil
    ) -> ZeroZeroWidgetActivityAttributes.ContentState {
        ZeroZeroWidgetActivityAttributes.ContentState(
            state: "running",
            value: value,
            progress: progress,
            items: items
        )
    }

    private func item(progress: Double? = nil, status: DashboardStatus? = nil) -> LiveActivityItem {
        LiveActivityItem(id: UUID().uuidString, title: "Item", progress: progress, status: status)
    }
}
