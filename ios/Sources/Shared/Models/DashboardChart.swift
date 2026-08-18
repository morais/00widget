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
    public var style: ChartStyle

    public init(
        points: [Double],
        min: Double? = nil,
        max: Double? = nil,
        style: ChartStyle = .line
    ) {
        self.points = points
        self.min = min
        self.max = max
        self.style = style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([Double].self, forKey: .points)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        let rawStyle = try c.decodeIfPresent(String.self, forKey: .style)
        style = rawStyle.flatMap(ChartStyle.init(rawValue:)) ?? .line
    }

    enum CodingKeys: String, CodingKey {
        case points, min, max, style
    }

    /// A single point is a dot, not a trend; the renderers fall back to the
    /// card's headline value instead of drawing one.
    public var isRenderable: Bool { points.count >= 2 }

    /// Heights in `0...1`, bottom-up, one per point. Points outside an explicit
    /// `min`/`max` clamp rather than overflow, so pinning the axis really does
    /// pin it. A series with no spread sits on the midline instead of dividing
    /// by zero. The guest link's browser page scales identically.
    public var normalizedPoints: [Double] {
        let lower = min ?? points.min() ?? 0
        let upper = max ?? points.max() ?? 0
        guard upper > lower else { return points.map { _ in 0.5 } }
        return points.map { Swift.min(1, Swift.max(0, ($0 - lower) / (upper - lower))) }
    }

    /// Spoken in place of the plot, which is decorative on its own.
    public var accessibilityDescription: String {
        guard let first = points.first, let last = points.last else { return "No chart data" }
        let direction = last > first ? "rising" : (last < first ? "falling" : "flat")
        return "Trend \(direction), \(points.count) points, from \(format(first)) to \(format(last))"
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
