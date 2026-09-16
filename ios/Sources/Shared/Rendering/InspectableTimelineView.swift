import SwiftUI

/// Detail-only timeline inspection. Widgets show the static overview; the app
/// and television let a person step through exact events chronologically.
public struct InspectableTimelineView: View {
    public let timeline: DashboardTimeline
    public let tint: Color
    public let plotHeight: CGFloat
    public let compact: Bool
    public let growsToFill: Bool

    @State private var selectedIndex: Int
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    public init(
        timeline: DashboardTimeline,
        tint: Color,
        plotHeight: CGFloat = 180,
        compact: Bool = false,
        growsToFill: Bool = false
    ) {
        self.timeline = timeline
        self.tint = tint
        self.plotHeight = plotHeight
        self.compact = compact
        self.growsToFill = growsToFill
        _selectedIndex = State(initialValue: max(0, timeline.entries.count - 1))
    }

    private var selectedEntry: DashboardTimelineEntry? {
        guard timeline.entries.indices.contains(selectedIndex) else { return nil }
        return timeline.entries[selectedIndex]
    }

    public var body: some View {
        let content = VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            GeometryReader { proxy in
                interactivePlot(width: proxy.size.width)
            }
            .frame(minHeight: plotHeight, maxHeight: growsToFill ? plotHeight * 2 : plotHeight)

            if let entry = selectedEntry {
                selectionPanel(entry)
            }
        }
        .onChange(of: timeline.entries.count) { _, count in
            selectedIndex = min(max(0, selectedIndex), max(0, count - 1))
        }

        #if os(tvOS)
        // Keep the plot as the actual focus target. Ignoring its children at
        // this level turns the whole timeline into a second, overlapping
        // focus element; the focus engine can then highlight the container
        // while left/right commands never reach `interactivePlot`.
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("timeline-inspector")
        #else
        content
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("timeline-inspector")
        .accessibilityLabel("Timeline events")
        .accessibilityValue(selectedEntry.map(accessibilityDescription) ?? "No timeline events")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: 1)
            case .decrement: move(by: -1)
            @unknown default: break
            }
        }
        #endif
    }

    @ViewBuilder
    private func interactivePlot(width: CGFloat) -> some View {
        let labelOffset: CGFloat = 78
        let usableWidth = max(0, width - labelOffset)
        let plot = EventTimelineView(
            timeline: timeline,
            tint: tint,
            showsLaneLabels: true,
            axisLabelCount: 3,
            legendLimit: DashboardTimeline.publishedSeriesLimit,
            lineWidth: 1.5,
            selectedPosition: selectedEntry.map { timeline.position(of: $0.at) }
        )
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
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("timeline-plot")
            .accessibilityLabel("Timeline events")
            .accessibilityValue(selectedEntry.map(accessibilityDescription) ?? "No timeline events")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(by: 1)
                case .decrement: move(by: -1)
                @unknown default: break
                }
            }
        #else
        plot.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    select(at: value.location.x - labelOffset, width: usableWidth)
                }
        )
        #endif
    }

    private func selectionPanel(_ entry: DashboardTimelineEntry) -> some View {
        let series = timeline.series.first { $0.id == entry.seriesId }
        let lane = timeline.lanes.first { $0.id == entry.laneId }
        return VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: 7) {
                if let icon = series?.icon { Image(systemName: icon) }
                Text(entry.label ?? series?.label ?? "Event").fontWeight(.semibold)
                Spacer(minLength: 8)
                if let status = entry.status {
                    StatusBadge(status: status, compact: true)
                }
            }
            HStack(spacing: 7) {
                if let lane { Text(lane.label) }
                if lane != nil { Text("·") }
                Text(timeDescription(entry))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(compact ? 10 : 14)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private func select(at x: CGFloat, width: CGFloat) {
        guard !timeline.entries.isEmpty, width > 0 else { return }
        let position = min(max(Double(x / width), 0), 1)
        selectedIndex = timeline.entries.indices.min {
            abs(timeline.position(of: timeline.entries[$0].at) - position)
                < abs(timeline.position(of: timeline.entries[$1].at) - position)
        } ?? selectedIndex
    }

    private func move(by amount: Int) {
        selectedIndex = min(max(0, selectedIndex + amount), max(0, timeline.entries.count - 1))
    }

    private func timeDescription(_ entry: DashboardTimelineEntry) -> String {
        if let endAt = entry.endAt {
            return "\(Self.timeFormatter.string(from: entry.at))–\(Self.timeFormatter.string(from: endAt))"
        }
        return Self.timeFormatter.string(from: entry.at)
    }

    private func accessibilityDescription(_ entry: DashboardTimelineEntry) -> String {
        let series = timeline.series.first { $0.id == entry.seriesId }?.label ?? "Event"
        let lane = timeline.lanes.first { $0.id == entry.laneId }?.label ?? "Timeline"
        let label = entry.label.map { ", \($0)" } ?? ""
        let status = entry.status.map { ", \($0.label)" } ?? ""
        return "\(series) on \(lane), \(timeDescription(entry))\(label)\(status), event \(selectedIndex + 1) of \(timeline.entries.count)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
