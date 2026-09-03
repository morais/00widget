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
        let nightlyRun = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("nightly-run") }
        )
        let solar = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("solar") }
        )
        let car = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("car-charge") }
        )
        let boiler = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("boiler") }
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
        #expect(energy.chart?.categories?.count { $0.signal == .caution } == 5)
        #expect(energy.chart?.categories?.count { $0.signal == .unfavorable } == 1)
        #expect(energyPoints.first == 21.8)
        #expect(solar.chart?.style == .line)
        #expect(solar.chart?.points.count == 7)
        #expect(solar.chart?.points.last == 3.2)
        #expect(solar.chart?.semantic?.signal == .favorable)
        #expect(deploys.items?.count == 20)
        #expect(deploys.items?.filter { $0.status == .critical }.map(\.value) == ["Failed", "Failed"])
        #expect(nightlyRun.template == .briefing)
        #expect(nightlyRun.progress == 0.6)
        #expect(nightlyRun.deadline != nil)
        #expect(nightlyRun.briefing?.sections.count == 3)
        #expect(car.displayValue == "62%")
        #expect(car.progress == 0.62)
        #expect(boiler.subtitle == "Manual mode")
        #expect(boiler.actions?.map(\.label) == ["Boost 1h"])
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

    /// The two samples exist to show the two layouts, which is only true while
    /// they stay on opposite sides of the rule that decides between them: item
    /// rows fill the Lock Screen banner and suppress a chart entirely, so a
    /// sample carrying both would silently demonstrate one of them twice.
    @Test("The two Live Activity samples demonstrate different layouts")
    func samplesCoverBothLayouts() throws {
        let battery = SampleDataFactory.makeLiveActivitySession(.homeBattery)
        #expect(battery.chart != nil)
        #expect((battery.items ?? []).isEmpty)

        let capture = SampleDataFactory.makeLiveActivitySession(.captureWorkflow)
        #expect(capture.chart == nil)
        #expect(capture.items?.count == 4)
        // Enough rows to exercise the Lock Screen's measured row ladder.
        #expect((capture.items ?? []).filter(\.isActive).count == 4)

        // Both, because they answer different questions and nothing derives
        // the second from the first — the exact mistake the server now warns
        // producers about.
        #expect(capture.value == "1/4")
        #expect(capture.progress == 0.25)

        // Short enough for the Dynamic Island's leading region, which is what
        // that warning asks for. A sample that broke its own rule would be the
        // first thing anyone copied.
        #expect(capture.title.count <= 24)

        // A sample that goes quiet has to say so like any other activity.
        for sample in SampleDataFactory.LiveActivitySample.allCases {
            #expect(SampleDataFactory.makeLiveActivitySession(sample).staleAt != nil)
        }
    }

    @Test("App Preview fixtures are stable at a reference date")
    func appPreviewFixturesAreStable() throws {
        let referenceDate = try #require(
            ZeroZeroWidgetDateFormat.parse("2026-09-01T09:41:00Z")
        )
        let cards = SampleDataFactory.makeMarketingPreviewCards(referenceDate: referenceDate)

        #expect(cards.map(\.title) == ["Julia turns 12", "Mars", "Beach this weekend?"])
        #expect(cards.map(\.value) == ["45", "225M", "YES"])
        #expect(cards.map(\.subtitle) == ["7 weekends", "12.5 light-minutes", "27°C · wind 11 km/h"])
        #expect(cards[1].chart?.style == .line)
        #expect(cards[1].chart?.points.last == 225)
        #expect(cards.last?.chart?.style == .range)
        #expect(cards.last?.chart?.semantic?.role == .forecast)
        #expect(cards.last?.chart?.ranges?.count == 7)
        #expect(cards.last?.chart?.ranges?.last?.high == 27)
        #expect(cards.allSatisfy { $0.isSample })
        #expect(cards.allSatisfy { !$0.isStale })
    }
}
