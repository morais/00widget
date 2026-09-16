import Foundation
import Testing
@testable import ZeroZeroWidgetApp

@Suite("Dashboard timeline")
struct DashboardTimelineTests {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let end = Date(timeIntervalSince1970: 1_600)

    private func timeline(entries: [DashboardTimelineEntry]) -> DashboardTimeline {
        DashboardTimeline(
            startAt: start,
            endAt: end,
            lanes: [DashboardTimelineLane(id: "main", label: "Main")],
            series: [DashboardTimelineSeries(id: "event", label: "Events")],
            entries: entries
        )
    }

    @Test("Entries are chronological and positions use elapsed time")
    func chronologicalGeometry() {
        let value = timeline(entries: [
            DashboardTimelineEntry(id: "late", laneId: "main", seriesId: "event", at: end),
            DashboardTimelineEntry(id: "early", laneId: "main", seriesId: "event", at: start),
            DashboardTimelineEntry(id: "middle", laneId: "main", seriesId: "event", at: Date(timeIntervalSince1970: 1_300)),
        ])

        #expect(value.entries.map(\.id) == ["early", "middle", "late"])
        #expect(value.position(of: start.addingTimeInterval(-60)) == 0)
        #expect(value.position(of: Date(timeIntervalSince1970: 1_300)) == 0.5)
        #expect(value.position(of: end.addingTimeInterval(60)) == 1)
    }

    @Test("Point and span entries survive the card JSON round trip")
    func jsonRoundTrip() throws {
        let value = timeline(entries: [
            DashboardTimelineEntry(id: "point", laneId: "main", seriesId: "event", at: start),
            DashboardTimelineEntry(
                id: "span",
                laneId: "main",
                seriesId: "event",
                at: start,
                endAt: end,
                label: "Quiet",
                status: .warning
            ),
        ])
        let card = DashboardCard(id: "timeline", template: .timeline, title: "Timeline", timeline: value)
        let data = try CardCache.jsonEncoder().encode(card)
        let decoded = try CardCache.jsonDecoder().decode(DashboardCard.self, from: data)

        #expect(decoded.timeline == value)
        #expect(decoded.timeline?.entries[0].isSpan == false)
        #expect(decoded.timeline?.entries[1].isSpan == true)
    }

    @Test("Decoding canonicalizes an older unsorted payload")
    func decodingSortsEntries() throws {
        let data = Data(#"""
        {
          "startAt":"1970-01-01T00:16:40Z",
          "endAt":"1970-01-01T00:26:40Z",
          "lanes":[{"id":"main","label":"Main"}],
          "series":[{"id":"event","label":"Events"}],
          "entries":[
            {"id":"late","laneId":"main","seriesId":"event","at":"1970-01-01T00:25:00Z"},
            {"id":"early","laneId":"main","seriesId":"event","at":"1970-01-01T00:18:00Z"}
          ]
        }
        """#.utf8)

        let decoded = try CardCache.jsonDecoder().decode(DashboardTimeline.self, from: data)
        #expect(decoded.entries.map(\.id) == ["early", "late"])
    }

    @Test("Accessibility summarizes instants and spans without reading every event")
    func accessibilitySummary() {
        let value = DashboardTimeline(
            startAt: start,
            endAt: end,
            lanes: [DashboardTimelineLane(id: "main", label: "Main")],
            series: [
                DashboardTimelineSeries(id: "motion", label: "Motion"),
                DashboardTimelineSeries(id: "quiet", label: "Quiet"),
            ],
            entries: [
                DashboardTimelineEntry(id: "m1", laneId: "main", seriesId: "motion", at: start),
                DashboardTimelineEntry(id: "m2", laneId: "main", seriesId: "motion", at: end),
                DashboardTimelineEntry(id: "q", laneId: "main", seriesId: "quiet", at: start, endAt: end),
            ]
        )

        #expect(value.accessibilityDescription.contains("2 Motion events"))
        #expect(value.accessibilityDescription.contains("1 Quiet period"))
        let card = DashboardCard(id: "timeline", template: .timeline, title: "Home", timeline: value)
        #expect(CardAccessibilitySummary.detail(for: card, rowLimit: 0).contains("2 Motion events"))
    }

    @Test("The dedicated sample exercises every supported series and both entry kinds")
    func sampleCoverage() {
        let card = SampleDataFactory.makeTimelineCard(referenceDate: end)
        #expect(card.template == .timeline)
        #expect(card.timeline?.lanes.count == 2)
        #expect(card.timeline?.series.count == DashboardTimeline.publishedSeriesLimit)
        #expect(card.timeline?.entries.contains(where: \.isSpan) == true)
        #expect(card.timeline?.entries.contains { !$0.isSpan } == true)
        #expect(card.timeline?.isRenderable == true)
    }

}
