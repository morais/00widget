import Foundation

public struct DashboardItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var value: String?
    public var unit: String?
    public var status: DashboardStatus?
    /// Meaning of this quantity. The public API accepts only role and flow on
    /// items; status remains the row's health/outcome signal.
    public var semantic: MetricSemantic?
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
        semantic: MetricSemantic? = nil,
        amount: Double? = nil,
        deepLink: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.unit = unit
        self.status = status
        self.semantic = semantic
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
        semantic = try c.decodeIfPresent(MetricSemantic.self, forKey: .semantic)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        deepLink = ZeroZeroWidgetDeepLinkPolicy.sanitize(
            try c.decodeIfPresent(URL.self, forKey: .deepLink)
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, value, unit, status, semantic, amount, deepLink
    }
}

/// Joining a number to the unit a producer sent with it.
///
/// A unit is a separate word — "1204 jobs", not "1204jobs" — except where the
/// symbol binds to the number, which is the convention for percent, degrees and
/// the like. Every other surface already read it that way: the shared guest
/// page joins them with a space, the chart inspector formats "18.4 kWh", and a
/// card's own headline draws the unit as a second `Text` beside the number. The
/// item rows on iOS and tvOS were the one place that concatenated the two
/// strings raw, so a `list` row read "1204jobs" on the phone and "1204 jobs" in
/// a browser showing the same card.
public enum ValueUnit {
    /// Symbols that are set tight against the number they qualify.
    private static let binding: Set<Character> = ["%", "°", "′", "″", "×", "‰"]

    public static func joined(_ value: String?, _ unit: String?) -> String? {
        guard let value else { return nil }
        guard let unit, !unit.isEmpty else { return value }
        if let first = unit.first, binding.contains(first) { return value + unit }
        return value + " " + unit
    }
}

public extension DashboardItem {
    /// The item's value and unit as one string. See `ValueUnit`.
    var displayValue: String? { ValueUnit.joined(value, unit) }
}

public extension DashboardCard {
    /// The card's value and unit as one string, for the surfaces that draw them
    /// as a single run of text rather than as two styled `Text`s.
    var displayValue: String? { ValueUnit.joined(value, unit) }
}
