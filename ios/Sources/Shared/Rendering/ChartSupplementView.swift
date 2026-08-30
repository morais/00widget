import SwiftUI

public enum ChartSeriesPalette {
    public static func tint(index: Int, base: Color) -> Color {
        switch index {
        case 0: return base
        case 1: return .purple
        case 2: return .teal
        case 3: return .orange
        default: return .secondary
        }
    }
}

/// Labels that stay outside the plot so its geometry remains identical in
/// WidgetKit, the app, Apple TV, and guest rendering. Small surfaces omit this
/// view; callers choose how much legend and axis context their canvas affords.
public struct ChartSupplementView: View {
    public let chart: DashboardChart
    public let tint: Color
    public let legendLimit: Int
    public let labelLimit: Int
    public let font: Font

    public init(
        chart: DashboardChart,
        tint: Color,
        legendLimit: Int,
        labelLimit: Int,
        font: Font = .caption2
    ) {
        self.chart = chart
        self.tint = tint
        self.legendLimit = legendLimit
        self.labelLimit = labelLimit
        self.font = font
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if legendLimit > 0, let series = chart.series, !series.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(series.prefix(legendLimit).enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(ChartSeriesPalette.tint(index: index, base: tint))
                                .frame(width: 6, height: 6)
                            Text(entry.label).lineLimit(1)
                        }
                    }
                }
                .font(font)
                .foregroundStyle(.secondary)
            }
            if labelLimit > 0, let labels = chart.labels, !labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(sampled(labels, limit: labelLimit), id: \.offset) { entry in
                        Text(entry.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if entry.offset != sampled(labels, limit: labelLimit).last?.offset {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .font(font)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func sampled(_ labels: [String], limit: Int) -> [(offset: Int, label: String)] {
        guard limit > 0, labels.count > limit, limit > 1 else {
            return Array(labels.prefix(max(0, limit)).enumerated()).map { ($0.offset, $0.element) }
        }
        return (0..<limit).map { slot in
            let index = slot * (labels.count - 1) / (limit - 1)
            return (index, labels[index])
        }
    }
}
