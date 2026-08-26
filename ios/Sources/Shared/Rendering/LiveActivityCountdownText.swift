import Foundation
import SwiftUI

public struct LiveActivityCountdownText: View {
    private let endsAt: Date
    private let granularity: CountdownGranularity

    public init(endsAt: Date, granularity: CountdownGranularity?) {
        self.endsAt = endsAt
        self.granularity = granularity ?? .second
    }

    @ViewBuilder
    public var body: some View {
        switch granularity {
        case .second:
            Text(endsAt, style: .timer)
        case .minute:
            TimelineView(.periodic(from: nextMinuteBoundary(endsAt: endsAt, after: Date()), by: 60)) { context in
                Text(Self.minuteText(endsAt: endsAt, now: context.date))
            }
        }
    }

    public static func minuteText(endsAt: Date, now: Date) -> String {
        let remaining = endsAt.timeIntervalSince(now)
        guard remaining > 0 else { return "~0 min" }

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

/// The first instant the displayed minute changes, so a minute-granularity
/// countdown ticks with the number rather than with the wall clock.
private func nextMinuteBoundary(endsAt: Date, after now: Date) -> Date {
    let remaining = endsAt.timeIntervalSince(now)
    guard remaining > 0 else { return now.addingTimeInterval(60) }

    let wholeMinutes = floor(remaining / 60)
    let boundary = endsAt.addingTimeInterval(-wholeMinutes * 60)
    return boundary > now ? boundary : now.addingTimeInterval(60)
}
