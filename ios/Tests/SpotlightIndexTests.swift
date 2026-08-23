import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// `SpotlightIndex.indexable` decides what leaves the app for a system-wide
/// index, which makes it a privacy boundary rather than a filter. Everything it
/// admits becomes answerable by Siri from a local cache, without the app
/// running and without whatever context the app would have shown alongside it.
@Suite("Spotlight indexing policy")
struct SpotlightIndexTests {

    @Test("A card the tenant published is indexed")
    func ownCardIsIndexed() {
        let own = card(id: "solar")
        #expect(SpotlightIndex.indexable([own]).map(\.id) == ["solar"])
    }

    /// Samples are generated on-device for someone who has never signed in.
    /// The SAMPLE badge that makes them honest in the app cannot follow a card
    /// into Spotlight, so they must not go.
    @Test("Sample cards are never indexed")
    func samplesAreExcluded() {
        let sample = card(id: ZeroZeroWidgetConstants.sampleCardIdPrefix + "solar")
        #expect(sample.isSample)
        #expect(SpotlightIndex.indexable([sample]).isEmpty)
    }

    /// A guest-link card belongs to another tenant and its owner can revoke
    /// the link at any moment. An index would outlive that revocation.
    @Test("Guest-link cards are never indexed")
    func guestCardsAreExcluded() {
        let guest = card(id: ZeroZeroWidgetConstants.guestCardIdPrefix + "solar")
        #expect(guest.isFromGuestLink)
        #expect(SpotlightIndex.indexable([guest]).isEmpty)
    }

    /// Same reasoning as a guest link, reached a different way: a shared card
    /// carries `sharedBy` and an id with no distinguishing prefix, so the
    /// prefix checks alone would let it through.
    @Test("Shared cards are never indexed, prefix or no prefix")
    func sharedCardsAreExcluded() {
        var shared = card(id: "solar")
        shared.sharedBy = SharedByInfo(ownerEmail: "someone@example.com", shareId: "s1")
        #expect(!shared.isFromGuestLink)
        #expect(SpotlightIndex.indexable([shared]).isEmpty)
    }

    @Test("A mixed list keeps only the tenant's own cards")
    func mixedListKeepsOnlyOwn() {
        var shared = card(id: "washer")
        shared.sharedBy = SharedByInfo(ownerEmail: "someone@example.com", shareId: "s1")

        let cards = [
            card(id: "solar"),
            card(id: ZeroZeroWidgetConstants.sampleCardIdPrefix + "demo"),
            card(id: ZeroZeroWidgetConstants.guestCardIdPrefix + "friend"),
            shared,
            card(id: "boiler")
        ]

        #expect(SpotlightIndex.indexable(cards).map(\.id) == ["solar", "boiler"])
    }

    /// Entering the sample state has to prune, not just skip. The call site
    /// donates the sample list, so an empty result is what removes whatever
    /// real cards were indexed a moment earlier.
    @Test("An all-sample list yields nothing to index")
    func allSamplesYieldNothing() {
        let samples = (1...3).map { card(id: ZeroZeroWidgetConstants.sampleCardIdPrefix + "\($0)") }
        #expect(SpotlightIndex.indexable(samples).isEmpty)
    }

    // MARK: - Entity mapping

    @Test("Value and unit are joined so a search for the two together matches")
    func valueAndUnitAreJoined() {
        var solar = card(id: "solar")
        solar.value = "3.4"
        solar.unit = "kW"
        #expect(DashboardCardEntity(solar).value == "3.4 kW")
    }

    @Test("A card with no value still carries a searchable status")
    func statusIsAlwaysPresent() {
        var boiler = card(id: "boiler")
        boiler.status = .critical
        let entity = DashboardCardEntity(boiler)
        #expect(entity.status == "Critical")
        #expect(entity.id == "boiler")
        #expect(entity.title == "Solar")
    }

    // MARK: - Helpers

    private func card(id: String) -> DashboardCard {
        DashboardCard(id: id, template: .summary, title: "Solar")
    }
}
