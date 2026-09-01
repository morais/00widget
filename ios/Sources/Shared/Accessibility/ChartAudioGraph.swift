import Accessibility
import SwiftUI

/// The audio graph behind an inspectable chart.
///
/// The inspector already speaks a summary and steps point by point, which is
/// the reading someone gets when they ask for one value. An audio graph is the
/// other reading: VoiceOver plays the series as pitch over time, so a shape —
/// a climb, a dip, a plateau — arrives as a shape rather than as sixty spoken
/// numbers. That is worth having on a dashboard whose whole purpose is metrics.
///
/// Everything here describes the *published* series, never the downsampled one
/// a narrow surface draws. Same rule as `SparklineView`'s label: the cap exists
/// because a Lock Screen accessory is 2.8 points per step, and a listener has
/// the same room everywhere.
public struct ChartAudioGraph: AXChartDescriptorRepresentable {
    public let chart: DashboardChart
    /// The card or activity the plot belongs to. VoiceOver announces it when
    /// the graph opens, and the plot alone has no name of its own.
    public let title: String?
    public let unit: String?

    public init(chart: DashboardChart, title: String? = nil, unit: String? = nil) {
        self.chart = chart
        self.title = title
        self.unit = unit
    }

    public func makeChartDescriptor() -> AXChartDescriptor {
        AXChartDescriptor(
            title: title,
            summary: chart.accessibilityDescription,
            xAxis: makeXAxis(),
            yAxis: makeYAxis(),
            series: makeSeries()
        )
    }

    /// Deliberately not left to the protocol's default, which does nothing.
    ///
    /// A card is a live object here — a push replaces its series while the
    /// detail screen is open — and the descriptor SwiftUI holds is the one it
    /// made the first time. Without this the audio graph would keep playing
    /// the series the screen opened with, silently, for as long as it stayed
    /// open.
    public func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        descriptor.title = title
        descriptor.summary = chart.accessibilityDescription
        descriptor.xAxis = makeXAxis()
        descriptor.yAxis = makeYAxis()
        descriptor.series = makeSeries()
    }

    // MARK: - Axes

    /// Category labels, but only when there is exactly one per point and no two
    /// are the same.
    ///
    /// A categorical axis is addressed *by label*: two points called "Mon" are
    /// one category as far as the axis is concerned, and the graph would then
    /// describe a series shorter than the one it plays. Repeated labels are
    /// ordinary — a 30-day chart labelled by weekday has four of each — so they
    /// fall back to a numbered axis that reads the label out instead.
    private var uniqueCategoryLabels: [String]? {
        guard let labels = chart.labels, labels.count == chart.points.count, !labels.isEmpty else {
            return nil
        }
        return Set(labels).count == labels.count ? labels : nil
    }

    private func makeXAxis() -> any AXDataAxisDescriptor {
        if let categories = uniqueCategoryLabels {
            return AXCategoricalDataAxisDescriptor(title: "Category", categoryOrder: categories)
        }
        return AXNumericDataAxisDescriptor(
            title: "Point",
            range: 1...Double(Swift.max(chart.points.count, 1)),
            gridlinePositions: [],
            valueDescriptionProvider: { position in
                positionDescription(at: Int(position.rounded()) - 1)
            }
        )
    }

    private func makeYAxis() -> AXNumericDataAxisDescriptor {
        let bounds = chart.valueBounds
        return AXNumericDataAxisDescriptor(
            title: unit ?? "Value",
            // The same range the plot is scaled against, so the pitch a value
            // plays at and the height it is drawn at are the same reading.
            range: bounds.lower...Swift.max(bounds.lower, bounds.upper),
            gridlinePositions: gridlinePositions,
            valueDescriptionProvider: { value in
                ChartInspectionSnapshot.format(value, unit: unit)
            }
        )
    }

    /// The rules the plot actually draws, and only those. A reference a pinned
    /// axis pushed off the plot is not drawn — announcing a gridline for it
    /// would claim a target the chart is not measuring against.
    private var gridlinePositions: [Double] {
        var positions: [Double] = []
        if let reference = chart.reference, chart.normalizedReference != nil {
            positions.append(reference)
        }
        if chart.normalizedZero != nil, !positions.contains(0) {
            positions.append(0)
        }
        return positions.sorted()
    }

    // MARK: - Series

    private func makeSeries() -> [AXDataSeriesDescriptor] {
        if chart.style == .range,
           let ranges = chart.ranges,
           ranges.count == chart.points.count {
            var descriptors = [descriptor(name: "Low", values: ranges.map(\.low))]
            // A representative marker is optional per interval. A series
            // covering only the intervals that have one would play against x
            // positions it does not occupy, so it is offered whole or not at
            // all.
            let markers = ranges.map(\.value)
            if markers.allSatisfy({ $0 != nil }) {
                descriptors.append(
                    descriptor(
                        name: chart.rangeValueLabel ?? "Value",
                        values: markers.compactMap { $0 }
                    )
                )
            }
            descriptors.append(descriptor(name: "High", values: ranges.map(\.high)))
            return descriptors
        }

        if let entries = chart.series, !entries.isEmpty {
            var descriptors = entries.map { descriptor(name: $0.label, values: $0.points) }
            if entries.count > 1 {
                // `points` is the per-position total the server always sends
                // alongside a multi-series chart. Named the same as the row
                // `inspection(at:)` appends, so stepping and listening agree.
                descriptors.append(descriptor(name: "Total", values: chart.points))
            }
            return descriptors
        }

        return [descriptor(name: singleSeriesName, values: chart.points)]
    }

    private var singleSeriesName: String {
        if let role = chart.semantic?.role { return role.rawValue.capitalized }
        if let title, !title.isEmpty { return title }
        return "Values"
    }

    private func descriptor(name: String, values: [Double]) -> AXDataSeriesDescriptor {
        AXDataSeriesDescriptor(
            name: name,
            // A line is a reading between its points; bars, deltas and
            // intervals are readings *at* them.
            isContinuous: chart.style == .line,
            dataPoints: values.enumerated().compactMap(dataPoint(at:value:))
        )
    }

    private func dataPoint(at index: Int, value: Double) -> AXDataPoint? {
        if let categories = uniqueCategoryLabels {
            guard categories.indices.contains(index) else { return nil }
            return AXDataPoint(x: categories[index], y: value, label: pointLabel(at: index))
        }
        return AXDataPoint(x: Double(index + 1), y: value, label: pointLabel(at: index))
    }

    /// What this position is called, with whatever the publisher said about it.
    /// A category's signal is the one piece of meaning that is otherwise drawn
    /// as a coloured band behind the point and nothing else.
    private func pointLabel(at index: Int) -> String? {
        let category = chart.categories.flatMap { $0.indices.contains(index) ? $0[index] : nil }
        let label = category?.label ?? chart.labels.flatMap {
            $0.indices.contains(index) ? $0[index] : nil
        }
        let words = [label, category?.signal?.rawValue].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: ", ")
    }

    private func positionDescription(at index: Int) -> String {
        if let label = pointLabel(at: index) { return label }
        return "Point \(index + 1)"
    }
}
