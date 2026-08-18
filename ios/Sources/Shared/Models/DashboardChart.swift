import Foundation

public enum ChartStyle: String, Codable, CaseIterable, Sendable {
    case line
    case bar
}

/// The numeric series behind a `chart` card. Mirrors `DashboardChartSchema` in
/// `server/src/types.ts`.
///
/// Points are plotted evenly spaced in the order given, oldest first. There are
/// no timestamps: a widget-sized plot has no room for an x axis, so the
/// renderer would discard them anyway.
public struct DashboardChart: Codable, Hashable, Sendable {
    /// What the server accepts from a publisher. Kept here as documentation
    /// rather than as a decoding limit — a longer series still draws, so a
    /// future server-side increase needs no app release.
    public static let publishedPointLimit = 10

    public var points: [Double]
    /// Pins the bottom of the plot. Nil scales to the series minimum.
    public var min: Double?
    /// Pins the top of the plot. Nil scales to the series maximum.
    public var max: Double?
    /// A target, budget, or threshold drawn as a dashed rule across the plot.
    public var reference: Double?
    public var style: ChartStyle

    public init(
        points: [Double],
        min: Double? = nil,
        max: Double? = nil,
        reference: Double? = nil,
        style: ChartStyle = .line
    ) {
        self.points = points
        self.min = min
        self.max = max
        self.reference = reference
        self.style = style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([Double].self, forKey: .points)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        reference = try c.decodeIfPresent(Double.self, forKey: .reference)
        let rawStyle = try c.decodeIfPresent(String.self, forKey: .style)
        style = rawStyle.flatMap(ChartStyle.init(rawValue:)) ?? .line
    }

    enum CodingKeys: String, CodingKey {
        case points, min, max, reference, style
    }

    /// A single point is a dot, not a trend; the renderers fall back to the
    /// card's headline value instead of drawing one.
    public var isRenderable: Bool { points.count >= 2 }

    /// The plotted range. An unpinned edge stretches to include `reference`,
    /// because a target the plot cannot show is worse than no target at all.
    private var bounds: (lower: Double, upper: Double) {
        var lower = min ?? points.min() ?? 0
        var upper = max ?? points.max() ?? 0
        if let reference {
            if min == nil { lower = Swift.min(lower, reference) }
            if max == nil { upper = Swift.max(upper, reference) }
        }
        return (lower, upper)
    }

    private func normalize(_ value: Double, in bounds: (lower: Double, upper: Double)) -> Double {
        guard bounds.upper > bounds.lower else { return 0.5 }
        return Swift.min(1, Swift.max(0, (value - bounds.lower) / (bounds.upper - bounds.lower)))
    }

    /// Heights in `0...1`, bottom-up, one per point. Points outside an explicit
    /// `min`/`max` clamp rather than overflow, so pinning the axis really does
    /// pin it. A series with no spread sits on the midline instead of dividing
    /// by zero. The guest link's browser page scales identically.
    public var normalizedPoints: [Double] {
        let bounds = self.bounds
        return points.map { normalize($0, in: bounds) }
    }

    /// Where to draw the reference rule, or nil when there is none — or when a
    /// pinned axis leaves it off the plot, in which case drawing it clamped to
    /// an edge would claim a target the card is not actually measuring against.
    public var normalizedReference: Double? {
        guard let reference else { return nil }
        let bounds = self.bounds
        guard reference >= bounds.lower, reference <= bounds.upper else { return nil }
        return normalize(reference, in: bounds)
    }

    /// Spoken in place of the plot, which is decorative on its own.
    public var accessibilityDescription: String {
        guard let first = points.first, let last = points.last else { return "No chart data" }
        let direction = last > first ? "rising" : (last < first ? "falling" : "flat")
        var description = "Trend \(direction), \(points.count) points, from \(format(first)) to \(format(last))"
        if let reference {
            description += ", against a reference of \(format(reference))"
        }
        return description
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
