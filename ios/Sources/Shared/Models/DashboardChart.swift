import Foundation

public enum ChartStyle: String, Codable, CaseIterable, Sendable {
    case line
    case bar
    /// `bar` anchored at zero rather than at the bottom of the range, so signed
    /// values grow up or down from a zero rule.
    case delta
    /// A floating vertical band from a low to a high value, with an optional
    /// current/typical value marked inside it.
    case range
}

public enum ChartStacking: String, Codable, CaseIterable, Sendable {
    case stacked
    case grouped
}

public enum MetricRole: String, Codable, CaseIterable, Sendable {
    case actual
    case forecast
    case baseline
    case target
    case capacity
    case balance
    case remainder
}

public enum MetricFlow: String, Codable, CaseIterable, Sendable {
    case inbound
    case outbound
}

public enum MetricSignal: String, Codable, CaseIterable, Sendable {
    case favorable
    case neutral
    case caution
    case unfavorable

    static func strongest<S: Sequence>(_ signals: S) -> MetricSignal? where S.Element == MetricSignal {
        signals.max { lhs, rhs in lhs.precedence < rhs.precedence }
    }

    private var precedence: Int {
        switch self {
        case .neutral: return 0
        case .favorable: return 1
        case .caution: return 2
        case .unfavorable: return 3
        }
    }
}

public struct MetricSemantic: Codable, Hashable, Sendable {
    public var role: MetricRole?
    public var flow: MetricFlow?
    public var signal: MetricSignal?

    public init(
        role: MetricRole? = nil,
        flow: MetricFlow? = nil,
        signal: MetricSignal? = nil
    ) {
        self.role = role
        self.flow = flow
        self.signal = signal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role).flatMap(MetricRole.init(rawValue:))
        flow = try c.decodeIfPresent(String.self, forKey: .flow).flatMap(MetricFlow.init(rawValue:))
        signal = try c.decodeIfPresent(String.self, forKey: .signal).flatMap(MetricSignal.init(rawValue:))
    }

    enum CodingKeys: String, CodingKey { case role, flow, signal }

    var accessibilityWords: [String] {
        [role?.rawValue, flow?.rawValue, signal?.rawValue].compactMap { $0 }
    }

    var isEmpty: Bool { role == nil && flow == nil && signal == nil }

    /// A child metric overrides only the meanings it specifies and inherits
    /// the rest from its chart. This lets a chart say "forecast" once while
    /// individual series still distinguish inbound from outbound.
    func overriding(_ fallback: MetricSemantic?) -> MetricSemantic? {
        let resolved = MetricSemantic(
            role: role ?? fallback?.role,
            flow: flow ?? fallback?.flow,
            signal: signal ?? fallback?.signal
        )
        return resolved.isEmpty ? nil : resolved
    }
}

// Source-compatible names for code written against the first chart-only
// release. The JSON wire format never carried these Swift type names.
public typealias ChartSemanticRole = MetricRole
public typealias ChartFlow = MetricFlow
public typealias ChartSignal = MetricSignal
public typealias DashboardChartSemantic = MetricSemantic

public struct DashboardChartCategory: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var signal: MetricSignal?

    public init(id: String, label: String, signal: MetricSignal? = nil) {
        self.id = id
        self.label = label
        self.signal = signal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        signal = try c.decodeIfPresent(String.self, forKey: .signal).flatMap(MetricSignal.init(rawValue:))
    }

    enum CodingKeys: String, CodingKey { case id, label, signal }
}

public struct DashboardChartSeries: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var points: [Double]
    public var semantic: MetricSemantic?

    public init(
        id: String,
        label: String,
        points: [Double],
        semantic: MetricSemantic? = nil
    ) {
        self.id = id
        self.label = label
        self.points = points
        self.semantic = semantic
    }
}

public struct DashboardChartRange: Codable, Hashable, Sendable {
    public var low: Double
    public var high: Double
    public var value: Double?

    public init(low: Double, high: Double, value: Double? = nil) {
        self.low = low
        self.high = high
        self.value = value
    }

    var fallbackValue: Double { value ?? (low + high) / 2 }
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
    public static let publishedPointLimit = 60

    public var points: [Double]
    /// Pins the bottom of the plot. Nil scales to the series minimum.
    public var min: Double?
    /// Pins the top of the plot. Nil scales to the series maximum.
    public var max: Double?
    /// A target, budget, or threshold drawn as a dashed rule across the plot.
    public var reference: Double?
    /// Meaning shared by a single points/range series and inherited by any
    /// multi-series entry that omits one of its own semantic dimensions.
    public var semantic: MetricSemantic?
    public var style: ChartStyle
    /// Optional category labels aligned one-for-one with `points`.
    public var labels: [String]?
    /// Rich category metadata aligned with `points`. The server also derives
    /// `labels`, so clients that predate categories retain the axis text.
    public var categories: [DashboardChartCategory]?
    /// Multiple non-negative series. The server always also supplies `points`
    /// as their per-position totals so builds that predate this field draw one
    /// truthful fallback series rather than losing the chart.
    public var series: [DashboardChartSeries]?
    public var stacking: ChartStacking
    /// Min/max bands aligned with `points`. The server stores `value` (or the
    /// midpoint when absent) in `points`, so older clients render a useful
    /// fallback line while newer builds draw the full interval.
    public var ranges: [DashboardChartRange]?

    public init(
        points: [Double],
        min: Double? = nil,
        max: Double? = nil,
        reference: Double? = nil,
        semantic: MetricSemantic? = nil,
        style: ChartStyle = .line,
        labels: [String]? = nil,
        categories: [DashboardChartCategory]? = nil,
        series: [DashboardChartSeries]? = nil,
        stacking: ChartStacking = .stacked,
        ranges: [DashboardChartRange]? = nil
    ) {
        self.points = points.isEmpty
            ? DashboardChart.fallbackPoints(series: series, ranges: ranges)
            : points
        self.min = min
        self.max = max
        self.reference = reference
        self.semantic = semantic
        self.style = style
        self.labels = labels ?? categories?.map(\.label)
        self.categories = categories
        self.series = series
        self.stacking = stacking
        self.ranges = ranges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        series = try c.decodeIfPresent([DashboardChartSeries].self, forKey: .series)
        ranges = try c.decodeIfPresent([DashboardChartRange].self, forKey: .ranges)
        categories = try c.decodeIfPresent([DashboardChartCategory].self, forKey: .categories)
        points = try c.decodeIfPresent([Double].self, forKey: .points)
            ?? DashboardChart.fallbackPoints(series: series, ranges: ranges)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        reference = try c.decodeIfPresent(Double.self, forKey: .reference)
        semantic = try c.decodeIfPresent(MetricSemantic.self, forKey: .semantic)
        let rawStyle = try c.decodeIfPresent(String.self, forKey: .style)
        style = rawStyle.flatMap(ChartStyle.init(rawValue:)) ?? .line
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? categories?.map(\.label)
        let rawStacking = try c.decodeIfPresent(String.self, forKey: .stacking)
        stacking = rawStacking.flatMap(ChartStacking.init(rawValue:)) ?? .stacked
    }

    enum CodingKeys: String, CodingKey {
        case points, min, max, reference, semantic, style, labels, categories, series, stacking, ranges
    }

    /// A single point is a dot, not a trend; the renderers fall back to the
    /// card's headline value instead of drawing one.
    public var isRenderable: Bool { points.count >= 2 }

    /// The same series reduced to at most `maxPoints`, for a surface too narrow
    /// to draw all of it — a 60-point series on the Lock Screen is 2.8pt per
    /// point against a 1.5pt stroke, which is a band rather than a trend.
    ///
    /// Points are averaged into `maxPoints` equal-width buckets rather than
    /// sampled. Both a stride and a shape-preserving pick (LTTB) were the
    /// alternatives, and both misreport: a stride's output depends on which
    /// phase it happens to land on, so a spike is drawn or lost depending on
    /// where it sits, and LTTB keeps real points but at irregular indices,
    /// which a renderer that spaces points evenly then draws at the wrong
    /// place in the window. Averaging keeps the window, the spacing, and every
    /// input point's contribution; what it gives up is amplitude, understating
    /// a spike rather than moving or inventing one. That is the same call the
    /// rest of this type makes — an out-of-range reference rule is dropped, not
    /// clamped to an edge it does not sit on.
    ///
    /// The understatement is bounded by the published limit: at
    /// `publishedPointLimit` into the narrowest cap the ratio is under 4:1, so
    /// a bucket is a handful of adjacent readings, not a whole regime.
    ///
    /// `min`, `max`, `reference` and `style` carry over untouched — a bucket
    /// mean lies between its inputs, so nothing that fitted a pinned axis
    /// before can fall outside it now. Range charts preserve the full envelope
    /// of each bucket instead: the lowest low, highest high, and the mean of
    /// any supplied value markers. That intentionally avoids understating an
    /// interval when several categories have to share one narrow column.
    public func downsampled(toAtMost maxPoints: Int) -> DashboardChart {
        guard maxPoints >= 2, points.count > maxPoints else { return self }
        var reduced = self
        let buckets = (0..<maxPoints).map { bucket in
            // Proportional boundaries, so a count that does not divide evenly
            // spreads the remainder across the series instead of piling it
            // into the last bucket.
            let start = points.count * bucket / maxPoints
            let end = Swift.max(start + 1, points.count * (bucket + 1) / maxPoints)
            return start..<end
        }
        reduced.points = buckets.map { range in
            let slice = points[range]
            return slice.reduce(0, +) / Double(slice.count)
        }
        if let series {
            reduced.series = series.map { entry in
                var entry = entry
                entry.points = buckets.map { range in
                    let slice = entry.points[range]
                    return slice.reduce(0, +) / Double(slice.count)
                }
                return entry
            }
        }
        if let chartRanges = self.ranges, chartRanges.count == points.count {
            reduced.ranges = buckets.map { bucket in
                let values = chartRanges[bucket]
                let current = values.compactMap(\.value)
                return DashboardChartRange(
                    low: values.map(\.low).min() ?? 0,
                    high: values.map(\.high).max() ?? 0,
                    value: current.isEmpty ? nil : current.reduce(0, +) / Double(current.count)
                )
            }
            reduced.points = reduced.ranges?.map(\.fallbackValue) ?? reduced.points
        }
        if let categories, categories.count == points.count {
            reduced.categories = buckets.map { bucket in
                let values = categories[bucket]
                let last = values.last ?? categories[bucket.lowerBound]
                return DashboardChartCategory(
                    id: last.id,
                    label: last.label,
                    signal: MetricSignal.strongest(values.compactMap(\.signal))
                )
            }
            reduced.labels = reduced.categories?.map(\.label)
        } else if let labels, labels.count == points.count {
            reduced.labels = buckets.map { labels[$0.index(before: $0.endIndex)] }
        }
        return reduced
    }

    /// The plotted range. An unpinned edge stretches to include `reference`,
    /// because a target the plot cannot show is worse than no target at all,
    /// and to include zero for `delta`, whose bars have nothing to grow from
    /// otherwise.
    private var bounds: (lower: Double, upper: Double) {
        let lows = ranges?.map(\.low) ?? []
        let highs = ranges?.map(\.high) ?? []
        var lower = min ?? Swift.min(points.min() ?? 0, lows.min() ?? points.min() ?? 0)
        var upper = max ?? Swift.max(points.max() ?? 0, highs.max() ?? points.max() ?? 0)
        var anchors: [Double] = []
        if let reference { anchors.append(reference) }
        if style == .delta { anchors.append(0) }
        for anchor in anchors {
            if min == nil { lower = Swift.min(lower, anchor) }
            if max == nil { upper = Swift.max(upper, anchor) }
        }
        return (lower, upper)
    }

    func normalizedValue(_ value: Double) -> Double {
        let bounds = self.bounds
        guard bounds.upper > bounds.lower else { return 0.5 }
        return Swift.min(1, Swift.max(0, (value - bounds.lower) / (bounds.upper - bounds.lower)))
    }

    /// Heights in `0...1`, bottom-up, one per point. Points outside an explicit
    /// `min`/`max` clamp rather than overflow, so pinning the axis really does
    /// pin it. A series with no spread sits on the midline instead of dividing
    /// by zero. The guest link's browser page scales identically.
    public var normalizedPoints: [Double] {
        let bounds = self.bounds
        guard bounds.upper > bounds.lower else { return points.map { _ in 0.5 } }
        return points.map { normalizedValue($0) }
    }

    /// Where to draw the reference rule, or nil when there is none — or when a
    /// pinned axis leaves it off the plot, in which case drawing it clamped to
    /// an edge would claim a target the card is not actually measuring against.
    public var normalizedReference: Double? {
        guard let reference else { return nil }
        let bounds = self.bounds
        guard reference >= bounds.lower, reference <= bounds.upper else { return nil }
        return normalizedValue(reference)
    }

    /// Where the zero rule sits for `delta` bars, or nil when the style is not
    /// `delta` or a pinned axis excludes zero — in which case the bars fall
    /// back to growing from the bottom like plain `bar`.
    public var normalizedZero: Double? {
        guard style == .delta else { return nil }
        let bounds = self.bounds
        guard bounds.lower <= 0, bounds.upper >= 0 else { return nil }
        return normalizedValue(0)
    }

    /// Spoken in place of the plot, which is decorative on its own.
    public var accessibilityDescription: String {
        guard let first = points.first, let last = points.last else { return "No chart data" }
        let direction = last > first ? "rising" : (last < first ? "falling" : "flat")
        var description = "Trend \(direction), \(points.count) points, from \(format(first)) to \(format(last))"
        if series?.isEmpty != false, let semantics = semantic?.accessibilityWords, !semantics.isEmpty {
            description += ", " + semantics.joined(separator: ", ")
        }
        if let reference {
            description += ", against a reference of \(format(reference))"
        }
        if let series, !series.isEmpty {
            description += ", \(series.count) series: " + series.map { entry in
                let semantics = resolvedSemantic(for: entry)?.accessibilityWords ?? []
                return semantics.isEmpty ? entry.label : "\(entry.label) (\(semantics.joined(separator: ", ")))"
            }.joined(separator: ", ")
        }
        if let ranges, let overallLow = ranges.map(\.low).min(), let overallHigh = ranges.map(\.high).max() {
            description += ", spanning \(format(overallLow)) to \(format(overallHigh))"
        }
        if let categories {
            let signaled = categories.compactMap(\.signal)
            for signal in MetricSignal.allCases {
                let count = signaled.filter { $0 == signal }.count
                if count > 0 { description += ", \(count) \(signal.rawValue) categories" }
            }
        }
        return description
    }

    func resolvedSemantic(for series: DashboardChartSeries) -> MetricSemantic? {
        (series.semantic ?? MetricSemantic()).overriding(semantic)
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func fallbackPoints(
        series: [DashboardChartSeries]?,
        ranges: [DashboardChartRange]?
    ) -> [Double] {
        if let ranges { return ranges.map(\.fallbackValue) }
        guard let series, let count = series.first?.points.count else { return [] }
        return (0..<count).map { index in
            series.reduce(0) { $0 + ($1.points.indices.contains(index) ? $1.points[index] : 0) }
        }
    }
}
