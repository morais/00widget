import Foundation

/// One horizontal row in an event timeline. Lanes describe the subject being
/// observed; series describe the kinds of event that can occur on it.
public struct DashboardTimelineLane: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// A renderer-independent event category. Presentation is deliberately owned
/// by the client: order gives each series a stable palette colour and marker.
public struct DashboardTimelineSeries: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var icon: String?

    public init(id: String, label: String, icon: String? = nil) {
        self.id = id
        self.label = label
        self.icon = icon
    }
}

/// An instant when `endAt` is nil, or a duration beginning at `at` otherwise.
public struct DashboardTimelineEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var laneId: String
    public var seriesId: String
    public var at: Date
    public var endAt: Date?
    public var label: String?
    public var status: DashboardStatus?

    public init(
        id: String,
        laneId: String,
        seriesId: String,
        at: Date,
        endAt: Date? = nil,
        label: String? = nil,
        status: DashboardStatus? = nil
    ) {
        self.id = id
        self.laneId = laneId
        self.seriesId = seriesId
        self.at = at
        self.endAt = endAt
        self.label = label
        self.status = status
    }

    public var isSpan: Bool { endAt != nil }
}

/// Timestamped events within one fixed observation window.
///
/// Unlike a numeric `DashboardChart`, spacing is proportional to elapsed time.
/// The whole window is snapshot state: publishers replace it on every upsert.
public struct DashboardTimeline: Codable, Hashable, Sendable {
    public static let publishedLaneLimit = 3
    public static let publishedSeriesLimit = 4
    public static let publishedEntryLimit = 60

    public var startAt: Date
    public var endAt: Date
    public var lanes: [DashboardTimelineLane]
    public var series: [DashboardTimelineSeries]
    public var entries: [DashboardTimelineEntry]

    public init(
        startAt: Date,
        endAt: Date,
        lanes: [DashboardTimelineLane],
        series: [DashboardTimelineSeries],
        entries: [DashboardTimelineEntry]
    ) {
        self.startAt = startAt
        self.endAt = endAt
        self.lanes = lanes
        self.series = series
        self.entries = entries.sorted {
            if $0.at != $1.at { return $0.at < $1.at }
            return $0.id < $1.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case startAt, endAt, lanes, series, entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startAt: try container.decode(Date.self, forKey: .startAt),
            endAt: try container.decode(Date.self, forKey: .endAt),
            lanes: try container.decode([DashboardTimelineLane].self, forKey: .lanes),
            series: try container.decode([DashboardTimelineSeries].self, forKey: .series),
            entries: try container.decode([DashboardTimelineEntry].self, forKey: .entries)
        )
    }

    public var isRenderable: Bool {
        endAt > startAt && !lanes.isEmpty && !series.isEmpty && !entries.isEmpty
    }

    public func position(of date: Date) -> Double {
        let duration = endAt.timeIntervalSince(startAt)
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(startAt) / duration, 0), 1)
    }

    public func laneIndex(for entry: DashboardTimelineEntry) -> Int? {
        lanes.firstIndex { $0.id == entry.laneId }
    }

    public func seriesIndex(for entry: DashboardTimelineEntry) -> Int? {
        series.firstIndex { $0.id == entry.seriesId }
    }

    public var accessibilityDescription: String {
        let duration = Self.durationFormatter.string(from: endAt.timeIntervalSince(startAt)) ?? "timeline"
        let counts: [String] = series.compactMap { series -> String? in
            let matching = entries.filter { $0.seriesId == series.id }
            guard !matching.isEmpty else { return nil }
            let spans = matching.filter(\.isSpan).count
            let instants = matching.count - spans
            var parts: [String] = []
            if instants > 0 { parts.append("\(instants) \(series.label) event\(instants == 1 ? "" : "s")") }
            if spans > 0 { parts.append("\(spans) \(series.label) period\(spans == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }
        guard !counts.isEmpty else { return "Last \(duration): no events" }
        return "Last \(duration): " + counts.joined(separator: ", ")
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
