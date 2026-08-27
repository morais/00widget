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

        let energyPoints = try #require(energy.chart?.points)
        #expect(energyPoints.count == 30)
        #expect(energyPoints.count <= DashboardChart.publishedPointLimit)
        #expect(deploys.items?.count == 20)
    }

    @Test("The demo Live Activity shows more than ten readings")
    func liveActivityUsesLongWindow() throws {
        let points = try #require(
            SampleDataFactory.makeLiveActivitySession().chart?.points
        )
        #expect(points.count == 24)
        #expect(points.count <= DashboardChart.publishedPointLimit)
    }
}
