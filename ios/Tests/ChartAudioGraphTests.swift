import Accessibility
import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// The audio graph is the one reading of a chart that nothing on screen can
/// show, so nothing on screen can show it going wrong either — a descriptor
/// built with the wrong axis or a missing series still renders a perfect plot.
@Suite("Chart audio graph")
struct ChartAudioGraphTests {
    @Test("A multi-series chart offers each series plus their total")
    func multiSeriesDescribesEverySeries() {
        let chart = DashboardChart(
            points: [],
            style: .bar,
            series: [
                DashboardChartSeries(id: "solar", label: "Solar", points: [1, 2, 3]),
                DashboardChartSeries(id: "grid", label: "Grid", points: [3, 2, 1]),
            ]
        )

        let descriptor = ChartAudioGraph(chart: chart, title: "Energy", unit: "kWh")
            .makeChartDescriptor()

        #expect(descriptor.title == "Energy")
        #expect(descriptor.series.map(\.name) == ["Solar", "Grid", "Total"])
        #expect(descriptor.series.allSatisfy { $0.dataPoints.count == 3 })
        // The totals the server derives, not a fourth series someone published.
        #expect(descriptor.series.last?.dataPoints.map { $0.yValue?.__number } == [4, 4, 4])
    }

    @Test("A single series is named for its role and is continuous only when drawn as a line")
    func singleSeriesNaming() {
        let line = DashboardChart(
            points: [1, 2],
            semantic: MetricSemantic(role: .forecast),
            style: .line
        )
        let lineDescriptor = ChartAudioGraph(chart: line, title: "Solar").makeChartDescriptor()
        #expect(lineDescriptor.series.map(\.name) == ["Forecast"])
        #expect(lineDescriptor.series[0].isContinuous)

        let bars = DashboardChart(points: [1, 2], style: .bar)
        let barDescriptor = ChartAudioGraph(chart: bars, title: "Solar").makeChartDescriptor()
        // No role to name it, so the card's own name is better than "Values".
        #expect(barDescriptor.series.map(\.name) == ["Solar"])
        #expect(barDescriptor.series[0].isContinuous == false)
    }

    @Test("Unique category labels become a categorical axis")
    func uniqueLabelsBecomeCategories() {
        let chart = DashboardChart(
            points: [1, 2, 3],
            style: .bar,
            categories: [
                DashboardChartCategory(id: "mon", label: "Mon"),
                DashboardChartCategory(id: "tue", label: "Tue", signal: .caution),
                DashboardChartCategory(id: "wed", label: "Wed"),
            ]
        )

        let descriptor = ChartAudioGraph(chart: chart).makeChartDescriptor()
        let axis = descriptor.xAxis as? AXCategoricalDataAxisDescriptor

        #expect(axis?.categoryOrder == ["Mon", "Tue", "Wed"])
        // A category's signal is otherwise only a coloured band behind the bar.
        #expect(descriptor.series[0].dataPoints.map(\.label) == ["Mon", "Tue, caution", "Wed"])
    }

    @Test("Repeated labels fall back to a numbered axis rather than collapsing points")
    func repeatedLabelsStayNumeric() {
        // A month of readings labelled by weekday: four Mondays are four
        // points, and a categorical axis addressed by label would be four
        // categories for eight points.
        let chart = DashboardChart(
            points: [1, 2, 3, 4],
            style: .bar,
            labels: ["Mon", "Tue", "Mon", "Tue"]
        )

        let descriptor = ChartAudioGraph(chart: chart).makeChartDescriptor()

        #expect(descriptor.xAxis is AXNumericDataAxisDescriptor)
        #expect(descriptor.series[0].dataPoints.count == 4)
        // The label is not lost — it moves onto the point.
        #expect(descriptor.series[0].dataPoints.map(\.label) == ["Mon", "Tue", "Mon", "Tue"])
    }

    @Test("The y axis is the range the plot is scaled against, with the rules it draws")
    func axisMatchesPlottedBounds() {
        let chart = DashboardChart(
            points: [10, 20],
            reference: 40,
            style: .line
        )

        let descriptor = ChartAudioGraph(chart: chart, unit: "kWh").makeChartDescriptor()

        // An unpinned edge stretches to include the reference, so the pitch a
        // value plays at is the height it is drawn at.
        #expect(descriptor.yAxis?.range == 10...40)
        #expect(descriptor.yAxis?.gridlinePositions == [40])
        #expect(descriptor.yAxis?.valueDescriptionProvider(20) == "20 kWh")
    }

    @Test("A reference a pinned axis excludes draws no gridline")
    func offPlotReferenceHasNoGridline() {
        let chart = DashboardChart(points: [1, 2], min: 0, max: 5, reference: 40, style: .line)
        let descriptor = ChartAudioGraph(chart: chart).makeChartDescriptor()

        #expect(descriptor.yAxis?.range == 0...5)
        #expect(descriptor.yAxis?.gridlinePositions.isEmpty == true)
    }

    @Test("Delta bars announce the zero rule they grow from")
    func deltaAnnouncesZero() {
        let chart = DashboardChart(points: [-2, 3], style: .delta)
        let descriptor = ChartAudioGraph(chart: chart).makeChartDescriptor()

        #expect(descriptor.yAxis?.gridlinePositions == [0])
    }

    @Test("A range chart offers its envelope, and its markers only when every interval has one")
    func rangeSeries() {
        let complete = DashboardChart(
            points: [],
            style: .range,
            rangeValueLabel: "Median",
            ranges: [
                DashboardChartRange(low: 1, high: 5, value: 3),
                DashboardChartRange(low: 2, high: 6, value: 4),
            ]
        )
        #expect(
            ChartAudioGraph(chart: complete).makeChartDescriptor().series.map(\.name)
                == ["Low", "Median", "High"]
        )

        // A marker series covering half the intervals would play against x
        // positions it does not occupy.
        let partial = DashboardChart(
            points: [],
            style: .range,
            ranges: [
                DashboardChartRange(low: 1, high: 5, value: 3),
                DashboardChartRange(low: 2, high: 6),
            ]
        )
        #expect(
            ChartAudioGraph(chart: partial).makeChartDescriptor().series.map(\.name)
                == ["Low", "High"]
        )
    }

    @Test("An updated card replaces the descriptor rather than leaving it at the series it opened with")
    func updateReplacesSeries() {
        let opened = DashboardChart(points: [1, 2], style: .line)
        let descriptor = ChartAudioGraph(chart: opened, title: "Solar").makeChartDescriptor()

        let pushed = DashboardChart(
            points: [],
            style: .bar,
            series: [
                DashboardChartSeries(id: "a", label: "A", points: [1, 2, 3]),
                DashboardChartSeries(id: "b", label: "B", points: [4, 5, 6]),
            ]
        )
        ChartAudioGraph(chart: pushed, title: "Energy").updateChartDescriptor(descriptor)

        #expect(descriptor.title == "Energy")
        #expect(descriptor.series.map(\.name) == ["A", "B", "Total"])
        #expect(descriptor.series[0].dataPoints.count == 3)
    }
}
