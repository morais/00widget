import Foundation
#if canImport(ActivityKit)
import ActivityKit

public struct ZeroWidgetActivityAttributes: ActivityAttributes, Hashable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var subtitle: String?
        public var state: String
        public var value: String?
        public var unit: String?
        public var progress: Double?
        public var updatedAt: Date
        public var staleAt: Date?

        public init(
            subtitle: String? = nil,
            state: String,
            value: String? = nil,
            unit: String? = nil,
            progress: Double? = nil,
            updatedAt: Date = Date(),
            staleAt: Date? = nil
        ) {
            self.subtitle = subtitle
            self.state = state
            self.value = value
            self.unit = unit
            self.progress = progress
            self.updatedAt = updatedAt
            self.staleAt = staleAt
        }
    }

    public var externalActivityId: String
    public var kind: LiveActivityKind
    public var title: String
    public var deepLink: URL?

    public init(
        externalActivityId: String,
        kind: LiveActivityKind = .generic,
        title: String,
        deepLink: URL? = nil
    ) {
        self.externalActivityId = externalActivityId
        self.kind = kind
        self.title = title
        self.deepLink = deepLink
    }
}

public extension ZeroWidgetActivityAttributes {
    static func from(_ session: LiveActivitySession) -> (ZeroWidgetActivityAttributes, ContentState) {
        let attrs = ZeroWidgetActivityAttributes(
            externalActivityId: session.externalActivityId,
            kind: session.kind,
            title: session.title,
            deepLink: session.deepLink
        )
        let state = ContentState(
            subtitle: session.subtitle,
            state: session.state,
            value: session.value,
            unit: session.unit,
            progress: session.progress,
            updatedAt: session.updatedAt,
            staleAt: session.staleAt
        )
        return (attrs, state)
    }
}
#endif
