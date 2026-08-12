import Foundation
#if canImport(ActivityKit)
import ActivityKit

public struct ZeroZeroWidgetActivityAttributes: ActivityAttributes, Hashable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var subtitle: String?
        public var state: String
        public var icon: String?
        public var value: String?
        public var unit: String?
        public var progress: Double?
        public var items: [LiveActivityItem]?
        public var endsAt: Date?
        public var countdownGranularity: CountdownGranularity?
        public var updatedAt: Date
        public var staleAt: Date?

        public init(
            subtitle: String? = nil,
            state: String,
            icon: String? = nil,
            value: String? = nil,
            unit: String? = nil,
            progress: Double? = nil,
            items: [LiveActivityItem]? = nil,
            endsAt: Date? = nil,
            countdownGranularity: CountdownGranularity? = nil,
            updatedAt: Date = Date(),
            staleAt: Date? = nil
        ) {
            self.subtitle = subtitle
            self.state = state
            self.icon = icon
            self.value = value
            self.unit = unit
            self.progress = progress
            self.items = items
            self.endsAt = endsAt
            self.countdownGranularity = countdownGranularity
            self.updatedAt = updatedAt
            self.staleAt = staleAt
        }
    }

    public var activityInstanceId: String?
    public var externalActivityId: String
    public var kind: LiveActivityKind
    public var title: String
    public var icon: String?
    public private(set) var deepLink: URL?

    public init(
        activityInstanceId: String? = nil,
        externalActivityId: String,
        kind: LiveActivityKind = .generic,
        title: String,
        icon: String? = nil,
        deepLink: URL? = nil
    ) {
        self.activityInstanceId = activityInstanceId
        self.externalActivityId = externalActivityId
        self.kind = kind
        self.title = title
        self.icon = icon
        self.deepLink = ZeroZeroWidgetDeepLinkPolicy.sanitize(deepLink)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activityInstanceId = try container.decodeIfPresent(String.self, forKey: .activityInstanceId)
        externalActivityId = try container.decode(String.self, forKey: .externalActivityId)
        kind = try container.decode(LiveActivityKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        deepLink = ZeroZeroWidgetDeepLinkPolicy.sanitize(
            try container.decodeIfPresent(URL.self, forKey: .deepLink)
        )
    }

    enum CodingKeys: String, CodingKey {
        case activityInstanceId, externalActivityId, kind, title, icon, deepLink
    }
}

public extension ZeroZeroWidgetActivityAttributes {
    static func from(_ session: LiveActivitySession) -> (ZeroZeroWidgetActivityAttributes, ContentState) {
        let attrs = ZeroZeroWidgetActivityAttributes(
            activityInstanceId: session.activityInstanceId,
            externalActivityId: session.externalActivityId,
            kind: session.kind,
            title: session.title,
            icon: session.icon,
            deepLink: session.deepLink
        )
        let state = ContentState(
            subtitle: session.subtitle,
            state: session.state,
            icon: session.icon,
            value: session.value,
            unit: session.unit,
            progress: session.progress,
            items: session.items,
            endsAt: session.endsAt,
            countdownGranularity: session.countdownGranularity,
            updatedAt: session.updatedAt,
            staleAt: session.staleAt
        )
        return (attrs, state)
    }
}
#endif
