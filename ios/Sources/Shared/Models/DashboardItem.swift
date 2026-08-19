import Foundation

public struct DashboardItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var value: String?
    public var unit: String?
    public var status: DashboardStatus?
    /// The row's magnitude, for templates that draw items rather than list
    /// them. Deliberately separate from `value`, which is a display string.
    public var amount: Double?
    /// Where this row goes when tapped, instead of the card's own `deepLink`.
    /// Sanitised on the way in, like every other link this app follows.
    public private(set) var deepLink: URL?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        unit: String? = nil,
        status: DashboardStatus? = nil,
        amount: Double? = nil,
        deepLink: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.unit = unit
        self.status = status
        self.amount = amount
        self.deepLink = ZeroZeroWidgetDeepLinkPolicy.sanitize(deepLink)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status)
        status = rawStatus.flatMap { DashboardStatus(rawValue: $0) }
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        deepLink = ZeroZeroWidgetDeepLinkPolicy.sanitize(
            try c.decodeIfPresent(URL.self, forKey: .deepLink)
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, value, unit, status, amount, deepLink
    }
}
