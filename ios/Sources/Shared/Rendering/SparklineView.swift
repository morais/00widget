import SwiftUI

/// Draws a `DashboardChart` as a sparkline: no axes, no gridlines, no labels.
/// It always shares its widget with a title and a headline value, and anything
/// more reads as noise at Home Screen sizes.
///
/// Everything here is `Shape`-based on purpose. WidgetKit archives the view
/// tree rather than running it, so `Canvas` is not available in the extension —
/// paths are, and they render identically in the app, the widget, and on tvOS.
public struct SparklineView: View {
    public let chart: DashboardChart
    public let tint: Color
    public let lineWidth: CGFloat
    public let showsArea: Bool
    /// How many points this surface has room to draw, or nil to draw the whole
    /// series. A publisher may send up to `DashboardChart.publishedPointLimit`,
    /// which the wide surfaces render in full and the narrow ones cannot: the
    /// caller knows its own width, so the cap is set per call site the way
    /// `lineWidth` already is.
    public let maxPoints: Int?

    public init(
        chart: DashboardChart,
        tint: Color,
        lineWidth: CGFloat = 2,
        showsArea: Bool = true,
        maxPoints: Int? = nil
    ) {
        self.chart = chart
        self.tint = tint
        self.lineWidth = lineWidth
        self.showsArea = showsArea
        self.maxPoints = maxPoints
    }

    /// Every piece of drawn geometry reads from this one, never from `chart`.
    /// The bounds of an unpinned axis are derived from the points themselves,
    /// so mixing the two would put the reference rule and the zero line at
    /// positions the plotted values were not scaled against.
    private var plotted: DashboardChart {
        guard let maxPoints else { return chart }
        return chart.downsampled(toAtMost: maxPoints)
    }

    public var body: some View {
        let plotted = self.plotted
        let values = plotted.normalizedPoints
        ZStack {
            if let reference = plotted.normalizedReference {
                HorizontalRuleShape(position: reference)
                    .stroke(
                        .secondary,
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
            }
            switch plotted.style {
            case .line:
                if showsArea {
                    SparklineAreaShape(values: values)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.32), tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                SparklineLineShape(values: values)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
            case .bar:
                if let series = plotted.series, series.count >= 2 {
                    let bands = plotted.normalizedSeriesBands
                    ForEach(Array(series.indices), id: \.self) { index in
                        MultiSeriesBarsShape(
                            bands: bands[index],
                            seriesIndex: index,
                            seriesCount: series.count,
                            stacking: plotted.stacking
                        )
                        .fill(ChartSeriesPalette.tint(index: index, base: tint).opacity(0.88))
                    }
                } else {
                    SparklineBarsShape(values: values)
                        .fill(tint.opacity(0.85))
                }
            case .delta:
                // Falling back to the bottom when a pinned axis excludes zero
                // keeps the bars honest: they are then plain magnitudes, drawn
                // without a zero rule that would not be where zero is.
                let baseline = plotted.normalizedZero
                SparklineBarsShape(values: values, baseline: baseline ?? 0, selection: .above)
                    .fill(tint.opacity(0.85))
                SparklineBarsShape(values: values, baseline: baseline ?? 0, selection: .below)
                    .fill(tint.opacity(0.4))
                if let baseline {
                    HorizontalRuleShape(position: baseline)
                        .stroke(.secondary, lineWidth: 0.75)
                }
            }
        }
        // A stroke is centred on the path, so the end points would be clipped
        // in half without room for it.
        .padding(.vertical, plotted.style == .line ? lineWidth / 2 : 0)
        .accessibilityElement()
        // Deliberately the full series, not the plotted one: the cap is a
        // property of how much room this surface has, and VoiceOver has the
        // same room everywhere. Someone listening should hear what was
        // published.
        .accessibilityLabel(Text(chart.accessibilityDescription))
    }
}

private struct NormalizedBarBand {
    let lower: Double
    let upper: Double
}

private extension DashboardChart {
    var normalizedSeriesBands: [[NormalizedBarBand]] {
        guard let series, let count = series.first?.points.count else { return [] }
        var cumulative = Array(repeating: 0.0, count: count)
        return series.map { entry in
            entry.points.enumerated().map { index, value in
                let lower = stacking == .stacked ? cumulative[index] : 0
                let upper = stacking == .stacked ? lower + value : value
                if stacking == .stacked { cumulative[index] = upper }
                return NormalizedBarBand(
                    lower: normalizedValue(lower),
                    upper: normalizedValue(upper)
                )
            }
        }
    }
}

private func sparklinePoints(_ values: [Double], in rect: CGRect) -> [CGPoint] {
    guard values.count > 1 else { return [] }
    let step = rect.width / CGFloat(values.count - 1)
    return values.enumerated().map { index, value in
        CGPoint(
            x: rect.minX + step * CGFloat(index),
            y: rect.maxY - rect.height * CGFloat(value)
        )
    }
}

/// A horizontal rule at a normalized height: the chart's reference value, and
/// the zero line `delta` bars grow from.
struct HorizontalRuleShape: Shape {
    let position: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.maxY - rect.height * CGFloat(position)
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        return path
    }
}

struct SparklineLineShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = sparklinePoints(values, in: rect)
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

struct SparklineAreaShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = sparklinePoints(values, in: rect)
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: rect.maxY))
        path.addLine(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct SparklineBarsShape: Shape {
    /// Which side of the baseline to draw, so signed bars can be filled
    /// differently without splitting the series into two arrays.
    enum Selection {
        case all
        case above
        case below
    }

    let values: [Double]
    let baseline: Double
    let selection: Selection

    init(values: [Double], baseline: Double = 0, selection: Selection = .all) {
        self.values = values
        self.baseline = baseline
        self.selection = selection
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty else { return path }
        let slot = rect.width / CGFloat(values.count)
        let barWidth = max(1, slot * 0.62)
        let radius = min(2, barWidth / 2)
        let baselineY = rect.maxY - rect.height * CGFloat(baseline)
        for (index, value) in values.enumerated() {
            if selection == .above && value < baseline { continue }
            if selection == .below && value >= baseline { continue }
            let valueY = rect.maxY - rect.height * CGFloat(value)
            // Every bar keeps a sliver of height so a value sitting on the
            // baseline still reads as a bar rather than as a missing point.
            let height = max(1, abs(valueY - baselineY))
            let bar = CGRect(
                x: rect.minX + slot * CGFloat(index) + (slot - barWidth) / 2,
                y: Swift.min(baselineY, valueY),
                width: barWidth,
                height: height
            )
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}

private struct MultiSeriesBarsShape: Shape {
    let bands: [NormalizedBarBand]
    let seriesIndex: Int
    let seriesCount: Int
    let stacking: ChartStacking

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !bands.isEmpty, seriesCount > 0 else { return path }
        let slot = rect.width / CGFloat(bands.count)
        let groupWidth = slot * 0.76
        let columnWidth = stacking == .stacked
            ? groupWidth
            : max(1, groupWidth / CGFloat(seriesCount))
        let groupStartInset = (slot - groupWidth) / 2
        let radius = min(2, columnWidth / 2)

        for (index, band) in bands.enumerated() {
            let lowerY = rect.maxY - rect.height * CGFloat(band.lower)
            let upperY = rect.maxY - rect.height * CGFloat(band.upper)
            let x = rect.minX + slot * CGFloat(index) + groupStartInset
                + (stacking == .grouped ? columnWidth * CGFloat(seriesIndex) : 0)
            let bar = CGRect(
                x: x,
                y: min(lowerY, upperY),
                width: columnWidth,
                height: max(1, abs(upperY - lowerY))
            )
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}
