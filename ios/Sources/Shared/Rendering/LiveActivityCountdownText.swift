import Foundation
import SwiftUI

public struct LiveActivityCountdownText: View {
    private let endsAt: Date
    private let granularity: CountdownGranularity
    private let ticking: TimeTicking

    public init(endsAt: Date, granularity: CountdownGranularity?, ticking: TimeTicking = .clock) {
        self.endsAt = endsAt
        self.granularity = granularity ?? .second
        self.ticking = ticking
    }

    @ViewBuilder
    public var body: some View {
        switch ticking {
        case .clock:
            TimelineView(CountdownDeadlineSchedule(endsAt: endsAt, granularity: granularity)) { context in
                remaining(at: context.date)
            }
        case .systemText:
            // A widget or Live Activity is drawn by the system out of process
            // and the schedule above never fires there — see `TimeTicking`. So
            // no timeline, and no "Overdue" either: reaching it depends on a
            // wake-up this surface does not get. `.second` keeps ticking
            // because `Text`'s `.timer` style is animated by the system itself;
            // `.minute` is a string computed when the system renders, which is
            // what it has always been here, and moves when the producer pushes.
            switch granularity {
            case .second:
                Text(endsAt, style: .timer)
            case .minute:
                Text(Self.minuteText(endsAt: endsAt, now: Date()))
            }
        }
    }

    /// A deadline that has passed says so, rather than parking on the last
    /// number before it.
    ///
    /// An ETA is an estimate, so overrunning it is ordinary — but "~0 min" is
    /// not a smaller estimate, it is a claim that the job is about to finish,
    /// and it stayed on screen for as long as anyone cared to look. Between
    /// that and a `.timer` quietly counting *up* past zero, the honest reading
    /// is that the estimate is spent and the countdown has nothing left to
    /// say.
    @ViewBuilder
    private func remaining(at now: Date) -> some View {
        if now >= endsAt {
            Text("Overdue")
        } else {
            switch granularity {
            case .second:
                Text(endsAt, style: .timer)
            case .minute:
                Text(Self.minuteText(endsAt: endsAt, now: now))
            }
        }
    }

    public static func minuteText(endsAt: Date, now: Date) -> String {
        let remaining = endsAt.timeIntervalSince(now)
        guard remaining > 0 else { return "Overdue" }

        let totalMinutes = max(1, Int(ceil(remaining / 60)))
        guard totalMinutes >= 60 else { return "~\(totalMinutes) min" }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "~\(hours)h" : "~\(hours)h \(minutes)m"
    }
}

/// The same countdown in two or three characters, for the Dynamic Island's
/// minimal circle.
///
/// That circle is about 24pt across, where `LiveActivityCountdownText` renders
/// "~1h 20m" and the system's own `.timer` style renders "1:19:58" — both of
/// which the region clips rather than shrinks. A single unit is all that fits,
/// so this rounds to the largest one that still says something: "45s", "12m",
/// "3h", "2d".
public struct LiveActivityCountdownToken: View {
    private let endsAt: Date
    private let granularity: CountdownGranularity

    public init(endsAt: Date, granularity: CountdownGranularity?) {
        self.endsAt = endsAt
        self.granularity = granularity ?? .second
    }

    /// The schedule is fixed when this view is built, and a Live Activity is
    /// rebuilt only when its content changes — so the second-by-second tick is
    /// chosen once, from the time left at build. Two minutes of headroom keeps
    /// the final minute live for an activity that stops updating before it
    /// ends; a longer window would spend a per-second timeline on a number
    /// that changes once an hour.
    @ViewBuilder
    public var body: some View {
        if granularity == .second, endsAt.timeIntervalSinceNow <= 120 {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(Self.tokenText(endsAt: endsAt, now: context.date))
            }
        } else {
            TimelineView(.periodic(from: nextMinuteBoundary(endsAt: endsAt, after: Date()), by: 60)) { context in
                Text(Self.tokenText(endsAt: endsAt, now: context.date))
            }
        }
    }

    /// Rounds *up* below the hour, so a countdown never claims to be further
    /// along than it is, and to nearest above it, where "1h" reads better than
    /// "2h" for sixty-one minutes. Each unit rolls into the next at its own
    /// boundary rather than at the raw interval, which is what stops "60m" and
    /// "24h" appearing a second before the unit above them would.
    public static func tokenText(endsAt: Date, now: Date) -> String {
        let remaining = endsAt.timeIntervalSince(now)
        guard remaining > 0 else { return "0m" }

        let seconds = Int(ceil(remaining))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = Int(ceil(remaining / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = Int((remaining / 3600).rounded())
        if hours < 24 { return "\(max(1, hours))h" }
        return "\(Int((remaining / 86_400).rounded()))d"
    }
}

/// Wakes the countdown when its text can actually change, and once more the
/// instant the deadline passes.
///
/// The deadline entry is the point. `Text(_, style: .timer)` redraws itself
/// and a minute countdown needs a minute's cadence, so both were already
/// covered — but neither can *stop*, and a Live Activity is rebuilt only when
/// its content state changes, which is precisely what a producer that has
/// overrun is no longer doing. Without an entry at `endsAt`, "Overdue" would
/// depend on the very update whose absence it is reporting.
private struct CountdownDeadlineSchedule: TimelineSchedule {
    let endsAt: Date
    let granularity: CountdownGranularity

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let entry = next
            next = Self.successor(after: entry, endsAt: endsAt, granularity: granularity)
            return entry
        }
    }

    private static func successor(
        after entry: Date,
        endsAt: Date,
        granularity: CountdownGranularity
    ) -> Date {
        // "Overdue" is terminal: nothing about it changes again. An hour is a
        // stand-in for never, since a schedule that stops emitting is not one
        // SwiftUI has a use for.
        guard entry < endsAt else { return entry.addingTimeInterval(3600) }
        let candidate: Date
        switch granularity {
        // `.timer` draws its own seconds, so across the whole life of the
        // activity this schedule wakes exactly once — at the deadline.
        case .second:
            candidate = endsAt
        case .minute:
            candidate = min(nextMinuteBoundary(endsAt: endsAt, after: entry), endsAt)
        }
        // A boundary that lands on or before the entry it follows would spin
        // the iterator on one date.
        return candidate > entry ? candidate : entry.addingTimeInterval(1)
    }
}

/// The first instant the displayed minute changes, so a minute-granularity
/// countdown ticks with the number rather than with the wall clock.
private func nextMinuteBoundary(endsAt: Date, after now: Date) -> Date {
    let remaining = endsAt.timeIntervalSince(now)
    guard remaining > 0 else { return now.addingTimeInterval(60) }

    let wholeMinutes = floor(remaining / 60)
    let boundary = endsAt.addingTimeInterval(-wholeMinutes * 60)
    return boundary > now ? boundary : now.addingTimeInterval(60)
}
