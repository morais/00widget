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
        #expect(energy.chart?.referenceMetadata?.semantic?.role == .target)
        #expect(energy.chart?.semantic?.role == .actual)
        #expect(energy.chart?.series?.map(\.label) == ["Solar", "Grid"])
        #expect(energy.chart?.series?.first?.semantic?.signal == .favorable)
        #expect(energy.chart?.series?.first?.semantic?.flow == .inbound)
        #expect(energy.chart?.stacking == .stacked)
        #expect(energy.chart?.labels?.count == energyPoints.count)
        #expect(energy.chart?.categories?.count == energyPoints.count)
        #expect(energy.chart?.categories?.contains { $0.signal == .caution } == true)
        #expect(energyPoints.first == 21.8)
        #expect(deploys.items?.count == 20)
        #expect(washer.template == .briefing)
        #expect(washer.briefing?.sections.count == 3)
    }

    @Test("The demo Live Activity shows a long charge-history line")
    func liveActivityUsesLongWindow() throws {
        let activity = SampleDataFactory.makeLiveActivitySession()
        let chart = try #require(activity.chart)
        #expect(activity.signal == .favorable)
        let points = chart.points
        #expect(points.count == 12)
        #expect(points.count <= DashboardChart.publishedPointLimit)
        #expect(chart.style == .line)
        #expect(chart.ranges == nil)
        #expect(chart.semantic?.role == .actual)
        #expect(chart.referenceMetadata?.semantic?.role == .capacity)
        #expect(chart.labels?.last == "Now")
        #expect(points.last == 95)
    }

    @Test("App Preview fixtures are stable at a reference date")
    func appPreviewFixturesAreStable() throws {
        let referenceDate = try #require(
            ZeroZeroWidgetDateFormat.parse("2026-09-01T09:41:00Z")
        )
        let cards = SampleDataFactory.makeMarketingPreviewCards(referenceDate: referenceDate)

        #expect(cards.map(\.title) == ["Julia turns 12", "Mars", "Beach this weekend?"])
        #expect(cards.map(\.value) == ["196", "225M", "YES"])
        #expect(cards.map(\.subtitle) == ["28 weekends", "12.5 light-minutes", "27°C · wind 11 km/h"])
        #expect(cards.allSatisfy { $0.isSample })
        #expect(cards.allSatisfy { !$0.isStale })
    }
}
