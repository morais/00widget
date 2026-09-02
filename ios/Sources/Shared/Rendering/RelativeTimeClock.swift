import SwiftUI

/// Redraws its content as the clock moves, so a relative timestamp inside it
/// counts up on its own.
///
/// `Text(updatedAt.formatted(.relative(...)))` is a string computed once, at
/// whatever moment something else caused a redraw. Scrolling a list hides
/// that, because scrolling redraws constantly. Two surfaces do not scroll and
/// are redrawn only when something arrives: an Apple TV left running on a
/// wall, where the line sat unchanged for a whole refresh interval and then
/// jumped from "18 seconds ago" to "38 seconds ago"; and a Live Activity,
/// which ActivityKit rebuilds only when its content state changes — so a
/// producer that has *stopped* sending is precisely the case where nothing
/// will ever provoke the redraw that would reveal it.
///
/// Nothing is threaded through to the content: the point is only that the body
/// is evaluated again, so the `Date()` inside the formatter — and inside
/// `isStale` — is read afresh. That second part is the real gain rather than a
/// side effect. Staleness used to be noticed only when something else provoked
/// a redraw, so an activity whose producer stopped went on presenting its last
/// numbers as current; now the surface says so on its own.
struct RelativeTimeClock<Content: View>: View {
    /// The timestamp being described. The schedule widens as it ages, so this
    /// decides how often the redraw happens.
    let since: Date
    @ViewBuilder var content: () -> Content

    var body: some View {
        TimelineView(RelativeTimeSchedule(since: since)) { _ in
            content()
        }
    }
}

/// One tick per unit the text can actually show.
///
/// A line reading in seconds has to redraw every second; one reading in minutes
/// cannot change more than once a minute however often it is asked, and past an
/// hour the wording moves so slowly that a lagging first transition costs
/// nothing. Waking a view more often than its own text can change is work
/// nobody sees — and on a Live Activity it is work paid for out of someone's
/// battery.
private struct RelativeTimeSchedule: TimelineSchedule {
    let since: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let entry = next
            next = entry.addingTimeInterval(Self.step(sinceAge: entry.timeIntervalSince(since), mode: mode))
            return entry
        }
    }

    private static func step(sinceAge age: TimeInterval, mode: TimelineScheduleMode) -> TimeInterval {
        // A timestamp in the future is a clock disagreement rather than a
        // state, and it is about to become a recent past one, so it takes the
        // finest cadence rather than the coarsest.
        guard mode != .lowFrequency else { return 60 }
        if age < 60 { return 1 }
        if age < 3600 { return 30 }
        return 300
    }
}
