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

public enum CountdownGranularity: String, Codable, Hashable, Sendable {
    case second
    case minute

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CountdownGranularity(rawValue: raw) ?? .second
    }
}

public struct LiveActivitySession: Codable, Hashable, Identifiable, Sendable {
    public var activityInstanceId: String?
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
    public var countdownGranularity: CountdownGranularity?
    public var startedAt: Date?
    public var updatedAt: Date
    public var staleAt: Date?
    // Smart Stack ranking on iPhone Lock Screen and Apple Watch. Higher wins.
    // Mirrors aps.relevance-score / ActivityContent.relevanceScore.
    public var relevanceScore: Double?
    public private(set) var deepLink: URL?
    public var actions: [ActionDefinition]?

    public var id: String { activityInstanceId ?? externalActivityId }

    public init(
        activityInstanceId: String? = nil,
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
        countdownGranularity: CountdownGranularity? = nil,
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        staleAt: Date? = nil,
        relevanceScore: Double? = nil,
        deepLink: URL? = nil,
        actions: [ActionDefinition]? = nil
    ) {
        self.activityInstanceId = activityInstanceId
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
        self.countdownGranularity = countdownGranularity
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.staleAt = staleAt
        self.relevanceScore = relevanceScore
        self.deepLink = ZeroZeroWidgetDeepLinkPolicy.sanitize(deepLink)
        self.actions = actions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activityInstanceId = try container.decodeIfPresent(String.self, forKey: .activityInstanceId)
        externalActivityId = try container.decode(String.self, forKey: .externalActivityId)
        kind = try container.decode(LiveActivityKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        state = try container.decode(String.self, forKey: .state)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        endsAt = try container.decodeIfPresent(Date.self, forKey: .endsAt)
        countdownGranularity = try container.decodeIfPresent(
            CountdownGranularity.self,
            forKey: .countdownGranularity
        )
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        staleAt = try container.decodeIfPresent(Date.self, forKey: .staleAt)
        relevanceScore = try container.decodeIfPresent(Double.self, forKey: .relevanceScore)
        deepLink = ZeroZeroWidgetDeepLinkPolicy.sanitize(
            try container.decodeIfPresent(URL.self, forKey: .deepLink)
        )
        actions = try container.decodeIfPresent([ActionDefinition].self, forKey: .actions)
    }

    enum CodingKeys: String, CodingKey {
        case activityInstanceId, externalActivityId, kind, title, subtitle, state, icon, value, unit
        case progress, endsAt, countdownGranularity, startedAt, updatedAt, staleAt
        case relevanceScore, deepLink, actions
    }
}
