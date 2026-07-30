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
            TimelineView(.periodic(from: nextMinuteBoundary(after: Date()), by: 60)) { context in
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

    private func nextMinuteBoundary(after now: Date) -> Date {
        let remaining = endsAt.timeIntervalSince(now)
        guard remaining > 0 else { return now.addingTimeInterval(60) }

        let wholeMinutes = floor(remaining / 60)
        let boundary = endsAt.addingTimeInterval(-wholeMinutes * 60)
        return boundary > now ? boundary : now.addingTimeInterval(60)
    }
}
