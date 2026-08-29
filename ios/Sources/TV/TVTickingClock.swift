import SwiftUI

/// Redraws its content as the clock moves, so a relative timestamp inside it
/// counts up on its own.
///
/// `Text(updatedAt.formatted(.relative(...)))` is a string computed once, at
/// whatever moment something else caused a redraw. On a phone that is hard to
/// notice, because scrolling and returning to a screen redraw it constantly. A
/// television left running on a wall redraws only when a fetch returns, so
/// "Updated 18 seconds ago" sat unchanged for a whole refresh interval and then
/// jumped straight to "38 seconds ago". Minutes hide that. Seconds do not.
///
/// Nothing is threaded through to the content: the point is only that the body
/// is evaluated again, so the `Date()` inside the formatter — and inside
/// `isStale` — is read afresh. That second part is a real gain rather than a
/// side effect. Staleness used to be noticed only when something else provoked
/// a redraw, so an activity whose producer stopped went on presenting its last
/// numbers as current; now the card says so on its own.
struct TVTickingClock<Content: View>: View {
    /// The timestamp being described. The schedule widens as it ages, so this
    /// decides how often the redraw happens.
    let since: Date
    @ViewBuilder var content: () -> Content

    var body: some View {
        TimelineView(TVRelativeTimeSchedule(since: since)) { _ in
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
/// nobody sees.
private struct TVRelativeTimeSchedule: TimelineSchedule {
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
