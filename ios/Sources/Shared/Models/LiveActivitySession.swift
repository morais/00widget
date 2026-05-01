import Foundation

public enum LiveActivityKind: String, Codable, CaseIterable, Sendable {
    case generic
    case progress
    case charging
    case appliance
    case job
    case timer

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LiveActivityKind(rawValue: raw) ?? .generic
    }
}

public struct LiveActivitySession: Codable, Hashable, Identifiable, Sendable {
    public var externalActivityId: String
    public var kind: LiveActivityKind
    public var title: String
    public var subtitle: String?
    public var state: String
    public var icon: String?
    public var value: String?
    public var unit: String?
    public var progress: Double?
    public var endsAt: Date?
    public var startedAt: Date?
    public var updatedAt: Date
    public var staleAt: Date?
    public var deepLink: URL?
    public var actions: [ActionDefinition]?

    public var id: String { externalActivityId }

    public init(
        externalActivityId: String,
        kind: LiveActivityKind = .generic,
        title: String,
        subtitle: String? = nil,
        state: String,
        icon: String? = nil,
        value: String? = nil,
        unit: String? = nil,
        progress: Double? = nil,
        endsAt: Date? = nil,
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        staleAt: Date? = nil,
        deepLink: URL? = nil,
        actions: [ActionDefinition]? = nil
    ) {
        self.externalActivityId = externalActivityId
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.icon = icon
        self.value = value
        self.unit = unit
        self.progress = progress
        self.endsAt = endsAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.staleAt = staleAt
        self.deepLink = deepLink
        self.actions = actions
    }
}
