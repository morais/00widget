import Testing
@testable import ZeroZeroWidgetApp

@Suite("Sample data")
struct SampleDataFactoryTests {
    @Test("Detailed demo cards use the larger published data windows")
    func detailedCardsUseLongWindows() throws {
        let cards = SampleDataFactory.makeCards()
        let energy = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("energy-trend") }
        )
        let deploys = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("deploys") }
        )
        let washer = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("washer") }
        )

        let energyPoints = try #require(energy.chart?.points)
        #expect(energyPoints.count == 30)
        #expect(energyPoints.count <= DashboardChart.publishedPointLimit)
        #expect(energy.chart?.style == .bar)
        #expect(energy.chart?.min == 0)
        #expect(energy.chart?.max == 30)
        #expect(energy.chart?.reference == 20)
        #expect(energy.chart?.series?.map(\.label) == ["Solar", "Grid"])
        #expect(energy.chart?.stacking == .stacked)
        #expect(energy.chart?.labels?.count == energyPoints.count)
        #expect(energyPoints.first == 21.8)
        #expect(deploys.items?.count == 20)
        #expect(washer.template == .briefing)
        #expect(washer.briefing?.sections.count == 3)
    }

    @Test("The demo Live Activity shows more than ten forecast ranges")
    func liveActivityUsesLongWindow() throws {
        let chart = try #require(SampleDataFactory.makeLiveActivitySession().chart)
        let points = chart.points
        #expect(points.count == 12)
        #expect(points.count <= DashboardChart.publishedPointLimit)
        #expect(chart.style == .range)
        #expect(chart.ranges?.count == points.count)
        #expect(points.last == 95)
    }
}
