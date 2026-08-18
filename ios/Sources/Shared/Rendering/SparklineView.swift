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

    public init(
        chart: DashboardChart,
        tint: Color,
        lineWidth: CGFloat = 2,
        showsArea: Bool = true
    ) {
        self.chart = chart
        self.tint = tint
        self.lineWidth = lineWidth
        self.showsArea = showsArea
    }

    public var body: some View {
        let values = chart.normalizedPoints
        ZStack {
            switch chart.style {
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
                SparklineBarsShape(values: values)
                    .fill(tint.opacity(0.85))
            }
        }
        // A stroke is centred on the path, so the end points would be clipped
        // in half without room for it.
        .padding(.vertical, chart.style == .line ? lineWidth / 2 : 0)
        .accessibilityElement()
        .accessibilityLabel(Text(chart.accessibilityDescription))
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
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty else { return path }
        let slot = rect.width / CGFloat(values.count)
        let barWidth = max(1, slot * 0.62)
        let radius = min(2, barWidth / 2)
        for (index, value) in values.enumerated() {
            // Every bar keeps a sliver of height so a series minimum still
            // reads as a bar rather than as a missing point.
            let height = max(1, rect.height * CGFloat(value))
            let bar = CGRect(
                x: rect.minX + slot * CGFloat(index) + (slot - barWidth) / 2,
                y: rect.maxY - height,
                width: barWidth,
                height: height
            )
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}
