import SwiftUI

/// A fixed-window event timeline. Geometry uses elapsed time rather than the
/// evenly-spaced categories of `SparklineView`.
public struct EventTimelineView: View {
    public let timeline: DashboardTimeline
    public let tint: Color
    public let showsLaneLabels: Bool
    public let axisLabelCount: Int
    public let legendLimit: Int
    public let lineWidth: CGFloat
    public let selectedPosition: Double?

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(
        timeline: DashboardTimeline,
        tint: Color,
        showsLaneLabels: Bool = false,
        axisLabelCount: Int = 0,
        legendLimit: Int = 0,
        lineWidth: CGFloat = 1,
        selectedPosition: Double? = nil
    ) {
        self.timeline = timeline
        self.tint = tint
        self.showsLaneLabels = showsLaneLabels
        self.axisLabelCount = axisLabelCount
        self.legendLimit = legendLimit
        self.lineWidth = lineWidth
        self.selectedPosition = selectedPosition
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if legendLimit > 0 {
                legend
            }
            HStack(alignment: .top, spacing: 6) {
                if showsLaneLabels {
                    laneLabels
                        .frame(width: 72)
                }
                plot
            }
            if axisLabelCount > 0 {
                HStack(spacing: 0) {
                    if showsLaneLabels { Color.clear.frame(width: 78, height: 1) }
                    axisLabels
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(timeline.accessibilityDescription))
    }

    private var plot: some View {
        GeometryReader { proxy in
            let laneHeight = proxy.size.height / CGFloat(max(1, timeline.lanes.count))
            ZStack(alignment: .topLeading) {
                ForEach(Array(timeline.lanes.indices), id: \.self) { laneIndex in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.20))
                        .frame(height: max(1, lineWidth))
                        .offset(y: laneHeight * (CGFloat(laneIndex) + 0.5))
                }

                ForEach(timeline.entries.filter(\.isSpan)) { entry in
                    span(entry, size: proxy.size, laneHeight: laneHeight)
                }
                ForEach(timeline.entries.filter { !$0.isSpan }) { entry in
                    marker(entry, size: proxy.size, laneHeight: laneHeight)
                }
                if let selectedPosition {
                    Rectangle()
                        .fill(tint.opacity(0.9))
                        .frame(width: 2, height: proxy.size.height)
                        .offset(x: max(1, min(proxy.size.width - 1, proxy.size.width * selectedPosition)) - 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    @ViewBuilder
    private func span(_ entry: DashboardTimelineEntry, size: CGSize, laneHeight: CGFloat) -> some View {
        if let laneIndex = timeline.laneIndex(for: entry),
           let seriesIndex = timeline.seriesIndex(for: entry),
           let endAt = entry.endAt {
            let startX = size.width * timeline.position(of: entry.at)
            let endX = size.width * timeline.position(of: endAt)
            let height = max(4, laneHeight * 0.62)
            let color = entry.status?.tint
                ?? ChartSeriesPalette.tint(index: seriesIndex, base: tint)
            RoundedRectangle(cornerRadius: min(3, height / 3), style: .continuous)
                .seriesFill(
                    color.opacity(
                        VisualAccommodations.fillOpacity(
                            0.24,
                            increasedContrast: colorSchemeContrast == .increased
                        )
                    ),
                    marker: SeriesMarker.at(seriesIndex),
                    textured: differentiateWithoutColor,
                    spacing: 4,
                    lineWidth: 0.75
                )
                .frame(width: max(2, endX - startX), height: height)
                .offset(
                    x: startX,
                    y: laneHeight * (CGFloat(laneIndex) + 0.5) - height / 2
                )
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func marker(_ entry: DashboardTimelineEntry, size: CGSize, laneHeight: CGFloat) -> some View {
        if let laneIndex = timeline.laneIndex(for: entry),
           let seriesIndex = timeline.seriesIndex(for: entry) {
            let markerSize = min(max(5, laneHeight * 0.42), 11)
            let rawX = size.width * timeline.position(of: entry.at)
            let x = min(max(markerSize / 2, rawX), max(markerSize / 2, size.width - markerSize / 2))
            let y = laneHeight * (CGFloat(laneIndex) + 0.5)
            let color = entry.status?.tint
                ?? ChartSeriesPalette.tint(index: seriesIndex, base: tint)
            Image(systemName: SeriesMarker.at(seriesIndex).symbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
                .frame(width: markerSize, height: markerSize)
                .offset(x: x - markerSize / 2, y: y - markerSize / 2)
                .accessibilityHidden(true)
        }
    }

    private var laneLabels: some View {
        GeometryReader { proxy in
            let laneHeight = proxy.size.height / CGFloat(max(1, timeline.lanes.count))
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(timeline.lanes) { lane in
                    Text(lane.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: laneHeight, maxHeight: laneHeight, alignment: .trailing)
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Array(timeline.series.prefix(legendLimit).enumerated()), id: \.element.id) { index, series in
                HStack(spacing: 4) {
                    SeriesSwatch(
                        index: index,
                        color: ChartSeriesPalette.tint(index: index, base: tint),
                        size: 7,
                        differentiateWithoutColor: differentiateWithoutColor
                    )
                    Text(series.label).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if timeline.series.count > legendLimit {
                Text("+\(timeline.series.count - legendLimit)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var axisLabels: some View {
        if axisLabelCount == 1 {
            Text(timeline.endAt, format: .dateTime.hour().minute())
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else if axisLabelCount == 2 {
            Text(timeline.startAt, format: .dateTime.hour().minute())
            Spacer()
            Text(timeline.endAt, format: .dateTime.hour().minute())
        } else {
            Text(timeline.startAt, format: .dateTime.hour().minute())
            Spacer()
            Text(timeline.startAt.addingTimeInterval(timeline.endAt.timeIntervalSince(timeline.startAt) / 2), format: .dateTime.hour().minute())
            Spacer()
            Text(timeline.endAt, format: .dateTime.hour().minute())
        }
    }
}
