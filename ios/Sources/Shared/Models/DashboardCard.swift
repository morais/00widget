import Foundation

public enum DashboardTemplate: String, Codable, CaseIterable, Sendable {
    case summary
    case progress
    case list
    case action
    case chart
    /// A run of outcomes rather than numbers: `items` drawn as status pips,
    /// oldest first.
    case history
    /// One bar split into proportional segments: `items` with an `amount`.
    case breakdown
    /// A short conclusion followed by ordered, progressively disclosed prose.
    case briefing
}

public struct SharedByInfo: Codable, Hashable, Sendable {
    public var ownerEmail: String
    public var shareId: String

    public init(ownerEmail: String, shareId: String) {
        self.ownerEmail = ownerEmail
        self.shareId = shareId
    }
}

/// The agent, automation, or service that published a card.
///
/// This is intentionally a label plus an optional SF Symbol, not a provider
/// enum. 00Widget presents the operator's own agents rather than coupling the
/// data model to a changing list of vendors.
public struct CardProducer: Codable, Hashable, Sendable {
    public var label: String
    public var icon: String?

    public init(label: String, icon: String? = nil) {
        self.label = label
        self.icon = icon
    }
}

/// A short, already-formatted comparison that gives the headline direction.
/// The value remains presentation text because producers own its unit and
/// locale; `signal` supplies meaning without granting control of a color.
public struct CardComparison: Codable, Hashable, Sendable {
    public var value: String
    public var label: String
    public var signal: MetricSignal

    public init(value: String, label: String, signal: MetricSignal = .neutral) {
        self.value = value
        self.label = label
        self.signal = signal
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
    public var statusIcon: String?
    public var producer: CardProducer?
    public var comparison: CardComparison?
    /// Where this card sits among the others. Higher first, absent counts as 0,
    /// ties broken by `id`. The server returns cards already in this order; the
    /// app and the widgets render the order they are given.
    public var priority: Int?
    /// How full the thing is, 0...1. The `progress` template used to carry this
    /// in `value`, which meant a progress card could show a bar or a headline
    /// number but never both — "3 of 12" was inexpressible. This is the same
    /// field a Live Activity has always had.
    public var progress: Double?
    public var updatedAt: Date
    public var staleAfter: Date?
    /// When the thing this card is about is due. Rendered as a relative
    /// countdown that the device ticks on its own, so it stays right between
    /// widget reloads — which a republished string cannot, given how rarely a
    /// Home Screen widget is allowed to reload.
    public var deadline: Date?
    public private(set) var deepLink: URL?
    public var items: [DashboardItem]?
    public var chart: DashboardChart?
    public var briefing: DashboardBriefing?
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
        statusIcon: String? = nil,
        producer: CardProducer? = nil,
        comparison: CardComparison? = nil,
        priority: Int? = nil,
        progress: Double? = nil,
        updatedAt: Date = Date(),
        staleAfter: Date? = nil,
        deadline: Date? = nil,
        deepLink: URL? = nil,
        items: [DashboardItem]? = nil,
        chart: DashboardChart? = nil,
        briefing: DashboardBriefing? = nil,
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
        self.statusIcon = statusIcon
        self.producer = producer
        self.comparison = comparison
        self.priority = priority
        self.progress = progress
        self.updatedAt = updatedAt
        self.staleAfter = staleAfter
        self.deadline = deadline
        self.deepLink = ZeroZeroWidgetDeepLinkPolicy.sanitize(deepLink)
        self.items = items
        self.chart = chart
        self.briefing = briefing
        self.actions = actions
        self.sharedBy = sharedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Falls back like `status` does rather than failing: an unknown value
        // means the server grew a template this build predates, and one such
        // card must not take the whole cached list down with it.
        let rawTemplate = try c.decode(String.self, forKey: .template)
        template = DashboardTemplate(rawValue: rawTemplate) ?? .summary
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        status = DashboardStatus(rawValue: rawStatus) ?? .unknown
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        statusIcon = try c.decodeIfPresent(String.self, forKey: .statusIcon)
        producer = try c.decodeIfPresent(CardProducer.self, forKey: .producer)
        comparison = try c.decodeIfPresent(CardComparison.self, forKey: .comparison)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        updatedAt = try DashboardCard.decodeDate(c, forKey: .updatedAt) ?? Date()
        staleAfter = try DashboardCard.decodeDate(c, forKey: .staleAfter)
        deadline = try DashboardCard.decodeDate(c, forKey: .deadline)
        deepLink = ZeroZeroWidgetDeepLinkPolicy.sanitize(
            try c.decodeIfPresent(URL.self, forKey: .deepLink)
        )
        items = try c.decodeIfPresent([DashboardItem].self, forKey: .items)
        chart = try c.decodeIfPresent(DashboardChart.self, forKey: .chart)
        briefing = try c.decodeIfPresent(DashboardBriefing.self, forKey: .briefing)
        actions = try c.decodeIfPresent([ActionDefinition].self, forKey: .actions)
        sharedBy = try c.decodeIfPresent(SharedByInfo.self, forKey: .sharedBy)
    }

    enum CodingKeys: String, CodingKey {
        case id, template, title, subtitle, value, unit, status, icon, statusIcon, producer, comparison
        case priority, progress, updatedAt, staleAfter, deadline, deepLink, items, chart, briefing, actions, sharedBy
    }

    public var isStale: Bool {
        if let staleAfter { return Date() >= staleAfter }
        return Date().timeIntervalSince(updatedAt) > 3600
    }

    /// A card reaching this device through a link somebody shared. Read-only:
    /// the server strips actions before it ever gets here.
    public var isFromGuestLink: Bool {
        id.hasPrefix(ZeroZeroWidgetConstants.guestCardIdPrefix)
    }

    public var isSample: Bool {
        id.hasPrefix(ZeroZeroWidgetConstants.sampleCardIdPrefix)
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
