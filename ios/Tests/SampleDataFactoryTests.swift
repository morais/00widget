import Testing
@testable import ZeroZeroWidgetApp

@Suite("Sample data")
struct SampleDataFactoryTests {
    @Test("Default cards form one internally consistent launch story")
    func defaultCardsTellLaunchStory() throws {
        let cards = SampleDataFactory.makeCards()
        #expect(cards.map(\.title) == [
            "Launch", "Production", "Trials", "Support", "AI spend",
            "Agent runs", "Launch message", "Open PRs",
        ])

        let launch = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("launch") }
        )
        let production = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("production") }
        )
        let trials = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("trials") }
        )
        let support = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("support") }
        )
        let spend = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("ai-spend") }
        )
        let runs = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("agent-runs") }
        )
        let message = try #require(
            cards.first { $0.id == SampleDataFactory.sampleId("launch-message") }
        )

        #expect(launch.template == .briefing)
        #expect(launch.value == "4/5")
        #expect(launch.progress == 0.8)
        #expect(launch.briefing?.sections.map(\.label) == ["Now", "Next", "Needs you"])
        #expect(launch.actions?.map(\.label) == ["Approve"])
        #expect(launch.needsUserAttention)

        #expect(production.items?.map(\.displayValue) == ["118 ms", "99.99%", "0 waiting"])
        #expect(production.items?.allSatisfy { $0.status == .good } == true)

        #expect(trials.chart?.points == [110, 111, 114, 116, 119, 123, 128])
        #expect(trials.chart?.reference == 110)
        #expect(trials.comparison == CardComparison(value: "+18", label: "vs Monday", signal: .favorable))

        #expect(support.items?.map(\.title) == ["Needs you", "Resolved", "Draft ready"])
        #expect(support.items?.map(\.amount) == [1, 18, 5])
        #expect(support.actions?.map(\.label) == ["Review"])
        #expect(support.needsUserAttention)

        #expect(spend.value == "$18.40")
        #expect(spend.progress == 0.613)
        #expect(runs.value == "20/20")
        #expect(runs.items?.count == 20)
        #expect(runs.items?.allSatisfy { $0.status == .good } == true)
        #expect(runs.items?.last?.subtitle == "Recovered after retry")
        #expect(message.actions?.map(\.label) == ["Approve"])

        #expect(cards.compactMap(\.producer?.label) == [
            "Release Agent", "Ops Agent", "Growth Agent", "Support Agent",
            "Usage Agent", "Run Agent", "Content Agent", "Code Agent",
        ])
    }

    @Test("The default Live Activity matches the launch card")
    func defaultActivityMatchesLaunch() throws {
        let activity = SampleDataFactory.makeLiveActivitySession()
        #expect(activity.title == "App launch")
        #expect(activity.subtitle == "Version 2.4 · five steps")
        #expect(activity.value == "4/5")
        #expect(activity.progress == 0.8)
        #expect(activity.state == "Waiting for approval")
        #expect(activity.signal == .caution)
        #expect(activity.items?.map(\.title) == ["Announcement", "Store", "Website", "Tests", "Build"])
        #expect(activity.items?.map(\.value) == ["Needs approval", "Uploaded", "Live", "412 passed", "Passed"])
        #expect(activity.activeItems.count == 1)
        #expect(activity.needsUserAttention)
        #expect(activity.endsAt != nil)
    }

    @Test("Both Live Activity jobs carry bounded progress and freshness")
    func activitySamplesAreBoundedAndFresh() throws {
        let launch = SampleDataFactory.makeLiveActivitySession(.appLaunch)
        #expect(launch.chart == nil)
        #expect(launch.items?.count == 5)

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
