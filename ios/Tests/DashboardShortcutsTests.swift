import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// The Siri shortcuts answer out loud, with no screen to qualify what they
/// say. That makes the wording the feature: a number read confidently is
/// indistinguishable from a correct one, so what the sentence omits matters as
/// much as what it includes.
@Suite("Card status shortcut wording")
struct CardStatusReportTests {

    @Test("A card with a value leads with the number and still names its status")
    func valueLeadsAndStatusFollows() {
        var solar = card()
        solar.value = "3.4"
        solar.unit = "kW"
        solar.status = .good

        #expect(CardStatusReport.summary(for: solar, now: solar.updatedAt) == "Solar is 3.4 kW. Status: good.")
    }

    /// The case the ordering exists for: a plain reading of the number says
    /// nothing is wrong, and the card says otherwise.
    @Test("A disagreeing status is never dropped in favour of the number")
    func statusSurvivesAHealthyLookingValue() {
        var solar = card()
        solar.value = "3.4"
        solar.unit = "kW"
        solar.status = .critical

        #expect(CardStatusReport.summary(for: solar, now: solar.updatedAt).contains("Status: critical."))
    }

    @Test("A card with no value falls back to the status word")
    func statusStandsInForAMissingValue() {
        var boiler = card(title: "Boiler")
        boiler.status = .offline

        #expect(CardStatusReport.summary(for: boiler, now: boiler.updatedAt) == "Boiler is offline.")
    }

    /// `unknown` is the decoder's fallback for a status this build predates, so
    /// it means "no answer", not "an answer called unknown". Saying it aloud
    /// alongside a real number is noise.
    @Test("An unknown status is not read out when the card has a value")
    func unknownStatusIsSilentBesideAValue() {
        var solar = card()
        solar.value = "3.4"
        solar.unit = "kW"
        solar.status = .unknown

        #expect(CardStatusReport.summary(for: solar, now: solar.updatedAt) == "Solar is 3.4 kW.")
    }

    @Test("A value without a unit reads without a trailing space")
    func valueWithoutUnit() {
        var deploys = card(title: "Deploys")
        deploys.value = "12"
        deploys.status = .good

        #expect(deploys.value != nil)
        #expect(CardStatusReport.summary(for: deploys, now: deploys.updatedAt) == "Deploys is 12. Status: good.")
    }

    @Test("Progress is reported as a percentage")
    func progressIsSpoken() {
        var washer = card(title: "Washer")
        washer.status = .running
        washer.progress = 0.42

        #expect(CardStatusReport.summary(for: washer, now: washer.updatedAt) == "Washer is running. 42% complete.")
    }

    /// Producers set this field, so it arrives unvalidated. A percentage over
    /// 100 or under 0 would be read out as fact.
    @Test("Progress outside 0...1 is clamped rather than read out as-is")
    func progressIsClamped() {
        var over = card(title: "Washer")
        over.progress = 1.8
        var under = card(title: "Washer")
        under.progress = -0.5

        #expect(CardStatusReport.summary(for: over, now: over.updatedAt).contains("100% complete."))
        #expect(CardStatusReport.summary(for: under, now: under.updatedAt).contains("0% complete."))
    }

    @Test("A subtitle is spoken and punctuated only if the producer did not")
    func subtitleIsPunctuatedOnce() {
        var bare = card()
        bare.subtitle = "Roof array"
        var punctuated = card()
        punctuated.subtitle = "Roof array!"

        #expect(CardStatusReport.summary(for: bare, now: bare.updatedAt).contains("Roof array."))
        #expect(CardStatusReport.summary(for: punctuated, now: punctuated.updatedAt).contains("Roof array!"))
        #expect(!CardStatusReport.summary(for: punctuated, now: punctuated.updatedAt).contains("Roof array!."))
    }

    /// Whitespace-only strings are the shape an empty producer field actually
    /// arrives in, and they would otherwise add a stray sentence made of a
    /// single full stop.
    @Test("Blank value and subtitle fields are treated as absent")
    func blankFieldsAreIgnored() {
        var blank = card()
        blank.value = "   "
        blank.unit = ""
        blank.subtitle = "  "
        blank.status = .good

        #expect(CardStatusReport.summary(for: blank, now: blank.updatedAt) == "Solar is good.")
    }

    @Test("A deadline is spoken relative to now")
    func deadlineIsRelative() {
        let now = Date()
        var washer = card(title: "Washer")
        washer.status = .running
        washer.deadline = now.addingTimeInterval(20 * 60)

        let summary = CardStatusReport.summary(for: washer, now: now)
        #expect(summary.contains("Due in 20 minutes."))
    }

    /// The whole reason this caveat exists: a stale card still has a number,
    /// and reading it without qualification states an hour-old value with a
    /// confidence it has not earned.
    @Test("A stale card carries an out-of-date caveat")
    func staleCardIsQualified() {
        let now = Date()
        var solar = card()
        solar.value = "3.4"
        solar.unit = "kW"
        solar.updatedAt = now.addingTimeInterval(-3 * 3600)
        solar.staleAfter = now.addingTimeInterval(-3600)

        #expect(solar.isStale)
        #expect(CardStatusReport.summary(for: solar, now: now).contains("This may be out of date"))
    }

    @Test("A fresh card says nothing about its update time")
    func freshCardIsNotQualified() {
        let now = Date()
        var solar = card()
        solar.value = "3.4"
        solar.unit = "kW"
        solar.updatedAt = now
        solar.staleAfter = now.addingTimeInterval(3600)

        #expect(!solar.isStale)
        #expect(!CardStatusReport.summary(for: solar, now: now).contains("out of date"))
    }

    // MARK: - Cards that are no longer there

    /// A card can vanish between Siri resolving the entity and the intent
    /// running — a `replacePrefix` batch upsert shrinks a namespace, a producer
    /// deletes, somebody signs out. Answering from the stale entity would
    /// report a value for something that no longer exists.
    @Test("A card missing from the cache is reported as gone, not guessed at")
    func missingCardSaysSo() {
        let answer = CardStatusReport.answer(
            forCardWithId: "definitely-not-in-the-cache-\(UUID().uuidString)",
            fallbackTitle: "Solar"
        )
        #expect(answer == "Solar is no longer published.")
    }

    // MARK: - Helpers

    private func card(title: String = "Solar") -> DashboardCard {
        DashboardCard(id: title.lowercased(), template: .summary, title: title)
    }
}

/// What Siri may resolve a spoken card name to. The query is the same one that
/// feeds Spotlight, so it inherits `SpotlightIndex.indexable` and can never
/// name a sample or another tenant's card — these cover the matching itself.
@Suite("Spoken card name matching")
struct DashboardCardEntityQueryMatchingTests {

    @Test("An exact title wins over a longer card that merely contains it")
    func exactTitleWins() {
        let cards = [card("Solar forecast"), card("Solar")]
        #expect(DashboardCardEntityQuery.matches("Solar", in: cards).map(\.title) == ["Solar"])
    }

    @Test("Matching ignores case and accents, because speech recognition does not preserve either")
    func matchingIsLoose() {
        let cards = [card("Café power")]
        #expect(DashboardCardEntityQuery.matches("cafe power", in: cards).map(\.title) == ["Café power"])
        #expect(DashboardCardEntityQuery.matches("CAFÉ POWER", in: cards).map(\.title) == ["Café power"])
    }

    @Test("A partial title matches, since producers title cards longer than people say them")
    func partialTitleMatches() {
        let cards = [card("Washer (kitchen)")]
        #expect(DashboardCardEntityQuery.matches("washer", in: cards).map(\.title) == ["Washer (kitchen)"])
    }

    /// Subtitle is the fallback, not a peer: a card whose *title* matches must
    /// never be crowded out by one that only mentions the word in its subtitle.
    @Test("Subtitles are searched only when no title matches")
    func subtitleIsTheFallback() {
        var mentionsInSubtitle = card("Boiler")
        mentionsInSubtitle.subtitle = "Feeds the washer"
        let titled = card("Washer")

        #expect(DashboardCardEntityQuery.matches("washer", in: [mentionsInSubtitle, titled]).map(\.title) == ["Washer"])
        #expect(DashboardCardEntityQuery.matches("washer", in: [mentionsInSubtitle]).map(\.title) == ["Boiler"])
    }

    /// An empty or whitespace query must not match everything — Siri handing
    /// back a blank would otherwise resolve to the entire dashboard.
    @Test("A blank query matches nothing")
    func blankQueryMatchesNothing() {
        let cards = [card("Solar"), card("Washer")]
        #expect(DashboardCardEntityQuery.matches("", in: cards).isEmpty)
        #expect(DashboardCardEntityQuery.matches("   ", in: cards).isEmpty)
    }

    @Test("Two cards sharing a title both come back rather than one being picked arbitrarily")
    func ambiguityIsPreserved() {
        let cards = [card("Solar", id: "a"), card("Solar", id: "b")]
        #expect(DashboardCardEntityQuery.matches("Solar", in: cards).map(\.id) == ["a", "b"])
    }

    private func card(_ title: String, id: String? = nil) -> DashboardCard {
        DashboardCard(id: id ?? title.lowercased(), template: .summary, title: title)
    }
}
