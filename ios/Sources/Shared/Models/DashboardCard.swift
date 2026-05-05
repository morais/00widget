import Foundation

public enum DashboardTemplate: String, Codable, CaseIterable, Sendable {
    case summary
    case progress
    case list
    case action

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DashboardTemplate(rawValue: raw) ?? .summary
    }
}

public struct SharedByInfo: Codable, Hashable, Sendable {
    public var ownerEmail: String
    public var shareId: String

    public init(ownerEmail: String, shareId: String) {
        self.ownerEmail = ownerEmail
        self.shareId = shareId
    }
}

public struct DashboardCard: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var template: DashboardTemplate
    public var title: String
    public var subtitle: String?
    public var value: String?
    public var unit: String?
    public var status: DashboardStatus
    public var icon: String?
    public var updatedAt: Date
    public var staleAfter: Date?
    public var deepLink: URL?
    public var items: [DashboardItem]?
    public var actions: [ActionDefinition]?
    public var sharedBy: SharedByInfo?

    public init(
        id: String,
        template: DashboardTemplate,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        unit: String? = nil,
        status: DashboardStatus = .unknown,
        icon: String? = nil,
        updatedAt: Date = Date(),
        staleAfter: Date? = nil,
        deepLink: URL? = nil,
        items: [DashboardItem]? = nil,
        actions: [ActionDefinition]? = nil,
        sharedBy: SharedByInfo? = nil
    ) {
        self.id = id
        self.template = template
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.unit = unit
        self.status = status
        self.icon = icon
        self.updatedAt = updatedAt
        self.staleAfter = staleAfter
        self.deepLink = deepLink
        self.items = items
        self.actions = actions
        self.sharedBy = sharedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let rawTemplate = try c.decode(String.self, forKey: .template)
        template = DashboardTemplate(rawValue: rawTemplate) ?? .summary
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        status = DashboardStatus(rawValue: rawStatus) ?? .unknown
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        updatedAt = try DashboardCard.decodeDate(c, forKey: .updatedAt) ?? Date()
        staleAfter = try DashboardCard.decodeDate(c, forKey: .staleAfter)
        deepLink = try c.decodeIfPresent(URL.self, forKey: .deepLink)
        items = try c.decodeIfPresent([DashboardItem].self, forKey: .items)
        actions = try c.decodeIfPresent([ActionDefinition].self, forKey: .actions)
        sharedBy = try c.decodeIfPresent(SharedByInfo.self, forKey: .sharedBy)
    }

    enum CodingKeys: String, CodingKey {
        case id, template, title, subtitle, value, unit, status, icon
        case updatedAt, staleAfter, deepLink, items, actions, sharedBy
    }

    public var isStale: Bool {
        if let staleAfter { return Date() >= staleAfter }
        return Date().timeIntervalSince(updatedAt) > 3600
    }

    private static func decodeDate(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Date? {
        if let s = try container.decodeIfPresent(String.self, forKey: key) {
            return ZeroZeroWidgetDateFormat.parse(s)
        }
        if let t = try container.decodeIfPresent(TimeInterval.self, forKey: key) {
            return Date(timeIntervalSince1970: t)
        }
        return nil
    }
}

public enum ZeroZeroWidgetDateFormat {
    public static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        iso.date(from: s) ?? isoNoFraction.date(from: s)
    }
}
