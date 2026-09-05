import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// When a card's typed attribution only repeats what its subtitle already
/// says.
///
/// `producer` arrived long after the convention it duplicates: every
/// integration guide taught a subtitle shaped `"<Agent> · <context>"`, and
/// producers kept writing them after gaining somewhere structured to put the
/// name. A card commonly carries the same words twice. On a phone that is
/// redundant; in a tvOS grid cell it costs a whole line out of the four or
/// five a card has, and the line it cost was being spent truncating one of the
/// two copies.
@Suite("Producer attribution")
struct ProducerAttributionTests {
    private func card(producer: String?, subtitle: String?) -> DashboardCard {
        DashboardCard(
            id: "c",
            template: .summary,
            title: "Card",
            subtitle: subtitle,
            producer: producer.map { CardProducer(label: $0) }
        )
    }

    @Test("A subtitle that opens with the producer's name repeats it")
    func detectsRepetition() {
        #expect(card(producer: "Growth Agent", subtitle: "Growth Agent · up 18").producerRepeatsSubtitle)
        #expect(card(producer: "Growth Agent", subtitle: "Growth Agent").producerRepeatsSubtitle)
        #expect(card(producer: "Growth Agent", subtitle: "growth agent — up 18").producerRepeatsSubtitle)
    }

    /// The match is on a whole word, which is the whole reason this is not a
    /// bare `hasPrefix`. "Growth" against "Growth Agent · up 18" is a
    /// different producer whose attribution says something the subtitle does
    /// not, and dropping it would lose information rather than save a line.
    @Test("A partial word is not a repetition")
    func requiresAWholeWord() {
        #expect(!card(producer: "Growth", subtitle: "Growth Agent · up 18").producerRepeatsSubtitle)
        #expect(!card(producer: "Ops", subtitle: "Opsgenie is quiet").producerRepeatsSubtitle)
    }

    @Test("A subtitle saying something else is left alone")
    func leavesDistinctSubtitlesAlone() {
        #expect(!card(producer: "Usage Agent", subtitle: "of $30 today · $11.60 left").producerRepeatsSubtitle)
        #expect(!card(producer: "Usage Agent", subtitle: nil).producerRepeatsSubtitle)
        #expect(!card(producer: nil, subtitle: "Usage Agent · today").producerRepeatsSubtitle)
    }

    /// The sample deck is what the App Store screenshots show, and it is
    /// deliberately written the way a real producer writes: five of its seven
    /// cards repeat their producer in the subtitle, so the renderer's handling
    /// of that is what a screenshot captures. Two do not, which is what keeps
    /// the attribution itself visible in those captures.
    @Test("The sample deck exercises both cases")
    func samplesCoverBothCases() {
        let cards = SampleDataFactory.makeCards()
        let repeated = cards.filter(\.producerRepeatsSubtitle).map(\.title)
        let distinct = cards.filter { $0.producer != nil && !$0.producerRepeatsSubtitle }.map(\.title)
        #expect(repeated == ["Launch", "Production", "Trials", "Support", "Open PRs"])
        #expect(distinct == ["AI spend", "Agent runs"])
    }
}
