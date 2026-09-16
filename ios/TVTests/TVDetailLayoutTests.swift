import SwiftUI
import Testing
@testable import ZeroZeroWidgetTV

@MainActor
@Suite("tvOS detail layout")
struct TVDetailLayoutTests {
    @Test("Large-type chart readings flow across available width")
    func chartReadingsFlowAcrossAvailableWidth() {
        let points = [1.0, 2.0]
        let chart = DashboardChart(
            points: [4, 8],
            min: 0,
            max: 10,
            reference: 6,
            referenceMetadata: DashboardChartReferenceMetadata(label: "Capacity"),
            semantic: MetricSemantic(role: .actual),
            style: .bar,
            labels: ["Before", "Now"],
            series: [
                DashboardChartSeries(id: "one", label: "One", points: points),
                DashboardChartSeries(id: "two", label: "Two", points: points),
                DashboardChartSeries(id: "three", label: "Three", points: points),
                DashboardChartSeries(id: "four", label: "Four", points: points),
            ]
        )
        let view = InspectableChartView(chart: chart, tint: .blue, plotHeight: 230, lineWidth: 6)

        let television = TVRenderProbe.height(
            of: view,
            width: 1_300,
            dynamicTypeSize: .accessibility3
        )

        #expect(
            television < 800,
            "The two-column large-type readout exceeded its 800-point regression ceiling (\(television))."
        )
    }
}
