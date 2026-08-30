import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The detail-only reading of a chart. Widgets keep the glanceable static
/// sparkline; a detail screen gets exact values and one selection shared by
/// touch, the Siri Remote, and accessibility adjustable actions.
public struct InspectableChartView: View {
    public let chart: DashboardChart
    public let tint: Color
    public let unit: String?
    public let plotHeight: CGFloat
    public let lineWidth: CGFloat
    public let compact: Bool

    @State private var selectedIndex: Int
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    public init(
        chart: DashboardChart,
        tint: Color,
        unit: String? = nil,
        plotHeight: CGFloat = 180,
        lineWidth: CGFloat = 3,
        compact: Bool = false
    ) {
        self.chart = chart
        self.tint = tint
        self.unit = unit
        self.plotHeight = plotHeight
        self.lineWidth = lineWidth
        self.compact = compact
        _selectedIndex = State(initialValue: max(0, chart.points.count - 1))
    }

    private var snapshot: ChartInspectionSnapshot? {
        chart.inspection(at: selectedIndex, unit: unit)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            GeometryReader { proxy in
                interactivePlot(width: proxy.size.width)
            }
            .frame(height: plotHeight)

            if let snapshot {
                selectionPanel(snapshot)
            }
        }
        .onChange(of: chart.points.count) { _, count in
            selectedIndex = min(max(0, selectedIndex), max(0, count - 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("chart-inspector")
        .accessibilityLabel("Chart values")
        .accessibilityValue(snapshot?.accessibilityDescription(unit: unit) ?? "No chart data")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: 1)
            case .decrement: move(by: -1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func interactivePlot(width: CGFloat) -> some View {
        let plot = ZStack {
            SparklineView(chart: chart, tint: tint, lineWidth: lineWidth)
            selectionIndicator(width: width)
        }
        .contentShape(Rectangle())

        #if os(tvOS)
        plot
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? tint.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isFocused ? tint : Color.secondary.opacity(0.22), lineWidth: isFocused ? 4 : 1)
            )
            .focusable()
            .focused($isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left: move(by: -1)
                case .right: move(by: 1)
                default: break
                }
            }
        #else
        plot
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in select(at: value.location.x, width: width) }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                        select(at: value.location.x, width: width)
                    }
            )
        #endif
    }

    @ViewBuilder
    private func selectionIndicator(width: CGFloat) -> some View {
        if !chart.points.isEmpty {
            let count = chart.points.count
            let categorical = chart.style != .line
            let slot = width / CGFloat(max(1, count))
            let x = categorical
                ? slot * (CGFloat(selectedIndex) + 0.5)
                : (count == 1 ? width / 2 : width * CGFloat(selectedIndex) / CGFloat(count - 1))

            ZStack(alignment: .topLeading) {
                if categorical {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .frame(width: max(4, slot * 0.78), height: plotHeight)
                        .offset(x: x - max(4, slot * 0.78) / 2)
                }
                Rectangle()
                    .fill(tint.opacity(0.9))
                    .frame(width: 2, height: plotHeight)
                    .offset(x: min(max(0, x - 1), max(0, width - 2)))
            }
            // Offsets do not contribute to layout. Without an explicit plot
            // frame this ZStack is only as wide as the 2pt selection rule, so
            // its origin is centred by the parent and every x position is
            // displaced by roughly half the chart width.
            .frame(width: width, height: plotHeight, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func selectionPanel(_ snapshot: ChartInspectionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            HStack(spacing: 8) {
                #if !os(tvOS)
                Button { move(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(snapshot.index == 0)
                .accessibilityHidden(true)
                #endif

                Text(snapshot.label)
                    .font(headerFont)
                    .lineLimit(1)
                if let signal = snapshot.signal {
                    Label(signal.rawValue.capitalized, systemImage: signal.symbolName)
                        .font(semanticFont)
                        .foregroundStyle(signal.tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(snapshot.index + 1) of \(snapshot.count)")
                    .font(semanticFont)
                    .foregroundStyle(.secondary)

                #if !os(tvOS)
                Button { move(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(snapshot.index == snapshot.count - 1)
                .accessibilityHidden(true)
                #endif
            }

            ForEach(Array(snapshot.values.enumerated()), id: \.element.id) { index, value in
                HStack(spacing: 8) {
                    valueMarker(value, index: index)
                    SemanticFlowIcon(value.semantic, font: semanticFont)
                    Text(value.label)
                        .font(valueFont)
                    if let words = value.semantic?.accessibilityWords, !words.isEmpty {
                        Text(words.joined(separator: " · "))
                            .font(semanticFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(ChartInspectionSnapshot.format(value.value, unit: unit))
                        .font(valueFont.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            if let comparison = snapshot.comparison {
                Label(comparison, systemImage: "arrow.left.and.right")
                    .font(semanticFont)
                    .foregroundStyle(.secondary)
            }

            #if os(tvOS)
            Text("Focus the chart, then press left or right to inspect values")
                .font(semanticFont)
                .foregroundStyle(.tertiary)
            #else
            Text("Tap or drag across the chart to inspect values")
                .font(semanticFont)
                .foregroundStyle(.tertiary)
            #endif
        }
        .padding(compact ? 10 : 14)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    @ViewBuilder
    private func valueMarker(_ value: ChartInspectionValue, index: Int) -> some View {
        if value.kind == .reference {
            Image(systemName: "minus")
                .foregroundStyle(ChartSeriesPalette.tint(index: index, base: tint, semantic: value.semantic))
        } else {
            Circle()
                .fill(ChartSeriesPalette.tint(index: index, base: tint, semantic: value.semantic))
                .frame(width: markerSize, height: markerSize)
        }
    }

    private var markerSize: CGFloat {
        #if os(tvOS)
        compact ? 10 : 14
        #else
        8
        #endif
    }

    private var headerFont: Font {
        #if os(tvOS)
        compact ? .headline : .title3.weight(.semibold)
        #else
        .headline
        #endif
    }

    private var valueFont: Font {
        #if os(tvOS)
        compact ? .callout : .headline
        #else
        .subheadline
        #endif
    }

    private var semanticFont: Font {
        #if os(tvOS)
        compact ? .caption : .callout
        #else
        .caption
        #endif
    }

    private func select(at x: CGFloat, width: CGFloat) {
        guard width > 0, !chart.points.isEmpty else { return }
        let fraction = min(max(0, x / width), 1)
        let index: Int
        if chart.style == .line, chart.points.count > 1 {
            index = Int((fraction * CGFloat(chart.points.count - 1)).rounded())
        } else {
            index = min(chart.points.count - 1, Int(fraction * CGFloat(chart.points.count)))
        }
        setSelection(index)
    }

    private func move(by offset: Int) {
        setSelection(selectedIndex + offset)
    }

    private func setSelection(_ index: Int) {
        guard !chart.points.isEmpty else { return }
        let clamped = min(max(0, index), chart.points.count - 1)
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}
