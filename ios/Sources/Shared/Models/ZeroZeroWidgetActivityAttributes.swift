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
        public var endsAt: Date?
        public var updatedAt: Date
        public var staleAt: Date?

        public init(
            subtitle: String? = nil,
            state: String,
            icon: String? = nil,
            value: String? = nil,
            unit: String? = nil,
            progress: Double? = nil,
            endsAt: Date? = nil,
            updatedAt: Date = Date(),
            staleAt: Date? = nil
        ) {
            self.subtitle = subtitle
            self.state = state
            self.icon = icon
            self.value = value
            self.unit = unit
            self.progress = progress
            self.endsAt = endsAt
            self.updatedAt = updatedAt
            self.staleAt = staleAt
        }
    }

    public var externalActivityId: String
    public var kind: LiveActivityKind
    public var title: String
    public var icon: String?
    public var deepLink: URL?

    public init(
        externalActivityId: String,
        kind: LiveActivityKind = .generic,
        title: String,
        icon: String? = nil,
        deepLink: URL? = nil
    ) {
        self.externalActivityId = externalActivityId
        self.kind = kind
        self.title = title
        self.icon = icon
        self.deepLink = deepLink
    }
}

public extension ZeroZeroWidgetActivityAttributes {
    static func from(_ session: LiveActivitySession) -> (ZeroZeroWidgetActivityAttributes, ContentState) {
        let attrs = ZeroZeroWidgetActivityAttributes(
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
            endsAt: session.endsAt,
            updatedAt: session.updatedAt,
            staleAt: session.staleAt
        )
        return (attrs, state)
    }
}
#endif
