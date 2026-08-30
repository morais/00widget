import SwiftUI

public enum ChartSeriesPalette {
    public static func tint(
        index: Int,
        base: Color,
        semantic: MetricSemantic? = nil
    ) -> Color {
        if let signal = semantic?.signal { return signalTint(signal, base: base) }
        if let flow = semantic?.flow {
            return flow == .inbound ? .teal : .purple
        }
        switch index {
        case 0: return base
        case 1: return .purple
        case 2: return .teal
        case 3: return .orange
        default: return .secondary
        }
    }

    public static func signalTint(_ signal: MetricSignal, base: Color) -> Color {
        signal.tint
    }

    public static func opacity(for role: MetricRole?) -> Double {
        switch role {
        case .forecast: return 0.48
        case .baseline: return 0.55
        case .target: return 0.72
        case .capacity: return 0.35
        case .remainder: return 0.45
        case .actual, .balance, .none: return 0.88
        }
    }

    public static func referenceDash(for role: MetricRole?) -> [CGFloat] {
        switch role {
        case .baseline: return [1, 3]
        case .capacity: return [6, 2]
        default: return [3, 3]
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
            if let metadata = chart.referenceMetadata,
               let label = metadata.displayLabel {
                HStack(spacing: 4) {
                    Capsule()
                        .fill(
                            ChartSeriesPalette.tint(
                                index: 0,
                                base: tint,
                                semantic: metadata.semantic
                            )
                            .opacity(ChartSeriesPalette.opacity(for: metadata.semantic?.role))
                        )
                        .frame(width: 14, height: 2)
                    Text(label).lineLimit(1)
                }
                .font(font)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text(
                        ([label] + (metadata.semantic?.accessibilityWords ?? []))
                            .joined(separator: ", ")
                    )
                )
            }
            if legendLimit > 0, let series = chart.series, !series.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(series.prefix(legendLimit).enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 3) {
                            if let flow = chart.resolvedSemantic(for: entry)?.flow {
                                Image(systemName: flow == .inbound ? "arrow.down" : "arrow.up")
                                    .font(.system(size: 7, weight: .bold))
                                    .accessibilityHidden(true)
                            }
                            Circle()
                                .fill(
                                    ChartSeriesPalette.tint(
                                        index: index,
                                        base: tint,
                                        semantic: chart.resolvedSemantic(for: entry)
                                    )
                                    .opacity(
                                        ChartSeriesPalette.opacity(
                                            for: chart.resolvedSemantic(for: entry)?.role
                                        )
                                    )
                                )
                                .frame(width: 6, height: 6)
                            Text(entry.label).lineLimit(1)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            Text(
                                ([entry.label] + (chart.resolvedSemantic(for: entry)?.accessibilityWords ?? []))
                                    .joined(separator: ", ")
                            )
                        )
                    }
                }
                .font(font)
                .foregroundStyle(.secondary)
            }
            if labelLimit > 0,
               let categories = chart.categories,
               categories.count == chart.points.count,
               !categories.isEmpty {
                let entries = sampled(categories, limit: labelLimit)
                HStack(spacing: 4) {
                    ForEach(entries, id: \.offset) { entry in
                        HStack(spacing: 2) {
                            if let signal = entry.category.signal {
                                Image(systemName: signalSymbol(signal))
                                    .foregroundStyle(ChartSeriesPalette.signalTint(signal, base: tint))
                                    .accessibilityHidden(true)
                            }
                            Text(entry.category.label)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            Text(
                                entry.category.signal.map {
                                    "\(entry.category.label), \($0.rawValue)"
                                } ?? entry.category.label
                            )
                        )
                        if entry.offset != entries.last?.offset {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .font(font)
                .foregroundStyle(.secondary)
            } else if labelLimit > 0, let labels = chart.labels, !labels.isEmpty {
                let entries = sampled(labels, limit: labelLimit)
                HStack(spacing: 4) {
                    ForEach(entries, id: \.offset) { entry in
                        Text(entry.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if entry.offset != entries.last?.offset { Spacer(minLength: 0) }
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

    private func sampled(
        _ categories: [DashboardChartCategory],
        limit: Int
    ) -> [(offset: Int, category: DashboardChartCategory)] {
        guard limit > 0, categories.count > limit, limit > 1 else {
            return Array(categories.prefix(max(0, limit)).enumerated()).map { ($0.offset, $0.element) }
        }
        return (0..<limit).map { slot in
            let index = slot * (categories.count - 1) / (limit - 1)
            return (index, categories[index])
        }
    }

    private func signalSymbol(_ signal: MetricSignal) -> String {
        signal.symbolName
    }
}
