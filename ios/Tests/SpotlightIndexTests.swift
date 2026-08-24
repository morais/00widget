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

    /// Checks the in-process attribute set only — which is the limit of what a
    /// test here can see, and worth stating because that limit has already cost
    /// two shipped builds. An `indexingKey` binding is applied by the system
    /// *over* this at index time, so a card can pass every assertion below and
    /// still show something else on device. The binding list is verified
    /// against `Metadata.appintents/extract.actionsdata` in the built app.
    @Test("The attribute set is populated from the bound properties")
    func attributeSetComesFromBindings() {
        var solar = card(id: "solar")
        solar.subtitle = "Roof array"
        solar.value = "3.4"
        solar.unit = "kW"
        solar.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let attributes = DashboardCardEntity(solar).attributeSet
        #expect(attributes.title == "Solar")
        #expect(attributes.contentDescription == "3.4 kW — Roof array")
        #expect(attributes.contentModificationDate == solar.updatedAt)
    }

    /// The value leads the result subtitle. A Spotlight row for a dashboard
    /// card exists to answer "what does it say right now"; a row showing only
    /// the card's static subtitle has told the person nothing.
    @Test("The value leads the result subtitle, and is a keyword too")
    func valueLeadsTheDescription() {
        var solar = card(id: "solar")
        solar.subtitle = "Roof array"
        solar.value = "3.4"
        solar.unit = "kW"
        solar.status = .critical

        let attributes = DashboardCardEntity(solar).attributeSet
        let keywords = attributes.keywords ?? []
        #expect(attributes.contentDescription == "3.4 kW — Roof array")
        #expect(keywords.contains("3.4 kW"))
        #expect(keywords.contains("Critical"))
        #expect(keywords.contains("Solar"))
    }

    /// A card with a value and no subtitle must not render a dangling
    /// separator, and one with neither must not render a bare " — ".
    @Test("The description joins only the parts that exist")
    func descriptionJoinsWhatExists() {
        var valueOnly = card(id: "solar")
        valueOnly.value = "3.4"
        valueOnly.unit = "kW"
        #expect(DashboardCardEntity(valueOnly).attributeSet.contentDescription == "3.4 kW")

        var subtitleOnly = card(id: "boiler")
        subtitleOnly.subtitle = "Roof array"
        #expect(DashboardCardEntity(subtitleOnly).attributeSet.contentDescription == "Roof array")

        let neither = card(id: "bare")
        #expect(DashboardCardEntity(neither).attributeSet.contentDescription == "")
    }

    /// Empty strings would otherwise become blank keywords, which match
    /// nothing and clutter the record.
    @Test("Absent fields do not become empty keywords")
    func absentFieldsAreNotKeywords() {
        let bare = card(id: "solar")
        let keywords = DashboardCardEntity(bare).attributeSet.keywords ?? []
        #expect(!keywords.contains(""))
        #expect(keywords.contains("Solar"))
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

/// The stored id set is a claim about what is *in Spotlight*, not a copy of the
/// last snapshot. It used to be written before the indexing work had even
/// started, which made a throw indistinguishable from a success — and, on the
/// delete path, permanently orphaned entries the app could no longer find to
/// remove. These pin the ordering invariant that fix rests on.
@Suite("Spotlight bookkeeping reconciliation")
struct SpotlightReconcileTests {

    @Test("When both halves succeed the stored set is the new snapshot")
    func bothSucceeded() {
        let believed = SpotlightIndex.reconcile(
            previous: ["a", "b"], current: ["b", "c"], deleted: true, indexed: true
        )
        #expect(believed == ["b", "c"])
    }

    /// The privacy-relevant one. "a" is gone from the dashboard and the delete
    /// threw, so it is still in Spotlight — and the stored set has to keep
    /// saying so, or nothing will ever compute it as departed again.
    @Test("A failed delete keeps the departed id, so the next donate retries it")
    func failedDeleteRetains() {
        let believed = SpotlightIndex.reconcile(
            previous: ["a", "b"], current: ["b", "c"], deleted: false, indexed: true
        )
        #expect(believed == ["a", "b", "c"])

        // And the retry follows: departed is recomputed from the stored set.
        #expect(believed.subtracting(["b", "c"]) == ["a"])
    }

    @Test("A failed index does not claim the new cards are searchable")
    func failedIndexDoesNotClaim() {
        let believed = SpotlightIndex.reconcile(
            previous: ["a", "b"], current: ["b", "c"], deleted: true, indexed: false
        )
        #expect(believed == ["b"])
    }

    @Test("When both halves fail the stored set does not move at all")
    func bothFailedIsANoOp() {
        let believed = SpotlightIndex.reconcile(
            previous: ["a", "b"], current: ["b", "c"], deleted: false, indexed: false
        )
        #expect(believed == ["a", "b"])
    }

    /// Entering the sample state donates an empty list. There is nothing to
    /// index, so `indexed` is vacuously true and the prune is the whole job.
    @Test("Pruning to nothing empties the stored set when the delete succeeds")
    func pruneToEmpty() {
        #expect(SpotlightIndex.reconcile(previous: ["a", "b"], current: [], deleted: true, indexed: true).isEmpty)
        #expect(SpotlightIndex.reconcile(previous: ["a", "b"], current: [], deleted: false, indexed: true) == ["a", "b"])
    }

    /// A card that stays in the snapshot is untouched by a failing delete of a
    /// different card — the departed set is the diff, not the whole previous
    /// set.
    @Test("A surviving card is never dropped by another card's failed delete")
    func survivorsAreUnaffected() {
        let believed = SpotlightIndex.reconcile(
            previous: ["a", "b"], current: ["a", "b"], deleted: false, indexed: false
        )
        #expect(believed == ["a", "b"])
    }

    @Test("A first donate from an empty index records exactly what it indexed")
    func firstDonate() {
        #expect(SpotlightIndex.reconcile(previous: [], current: ["a"], deleted: true, indexed: true) == ["a"])
        #expect(SpotlightIndex.reconcile(previous: [], current: ["a"], deleted: true, indexed: false).isEmpty)
    }
}

/// The system's re-index request is the only path that repairs the index
/// without the app being opened, which makes it the answer to the staleness
/// `CardCache.save` from the widget extension creates. It speaks only for the
/// ids it was handed, and that is the whole difference from a donation: a
/// snapshot knows what has gone, a request does not.
@Suite("Spotlight targeted re-index")
struct SpotlightReindexTests {

    @Test("Ids this device still holds are the ones re-donated")
    func heldIdsAreReindexed() {
        let (present, missing) = SpotlightIndex.split(
            ids: ["solar", "boiler"],
            among: [card(id: "solar"), card(id: "boiler"), card(id: "washer")]
        )
        #expect(present.map(\.id).sorted() == ["boiler", "solar"])
        #expect(missing.isEmpty)
    }

    @Test("An id this device no longer holds is pruned, not skipped")
    func deletedIdIsPruned() {
        let (present, missing) = SpotlightIndex.split(
            ids: ["solar", "deleted"],
            among: [card(id: "solar")]
        )
        #expect(present.map(\.id) == ["solar"])
        #expect(missing == ["deleted"])
    }

    /// The privacy-relevant half. The card is still in the cache, so a check
    /// for "do we have this id" would answer yes and re-donate somebody else's
    /// state. `indexable` is what decides, exactly as it does for a donation.
    @Test("An id that stopped being ours to index is pruned")
    func revokedIdIsPruned() {
        var shared = card(id: "washer")
        shared.sharedBy = SharedByInfo(ownerEmail: "someone@example.com", shareId: "s1")

        let (present, missing) = SpotlightIndex.split(
            ids: ["washer"],
            among: [shared]
        )
        #expect(present.isEmpty)
        #expect(missing == ["washer"])
    }

    @Test("Cards the request did not name are not touched either way")
    func unmentionedCardsAreIgnored() {
        let (present, missing) = SpotlightIndex.split(
            ids: ["solar"],
            among: [card(id: "solar"), card(id: "boiler")]
        )
        #expect(present.map(\.id) == ["solar"])
        #expect(missing.isEmpty)
    }

    @Test("When both halves succeed the named ids move and nothing else does")
    func bothSucceeded() {
        let believed = SpotlightIndex.reconcile(
            previous: ["solar", "boiler", "washer"],
            reindexed: ["solar"],
            pruned: ["boiler"],
            deleted: true,
            indexed: true
        )
        #expect(believed == ["solar", "washer"])
    }

    /// The same invariant the donation path has: a throw is not a state change,
    /// and a failed delete must keep saying the entry is in Spotlight so a
    /// later donate can compute it as departed and try again.
    @Test("A failed prune keeps the id, so a later donate retries it")
    func failedPruneRetains() {
        let believed = SpotlightIndex.reconcile(
            previous: ["solar", "boiler"],
            reindexed: ["solar"],
            pruned: ["boiler"],
            deleted: false,
            indexed: true
        )
        #expect(believed == ["solar", "boiler"])
    }

    @Test("A failed re-index does not claim a card is searchable")
    func failedReindexDoesNotClaim() {
        let believed = SpotlightIndex.reconcile(
            previous: ["boiler"],
            reindexed: ["solar"],
            pruned: [],
            deleted: true,
            indexed: false
        )
        #expect(believed == ["boiler"])
    }

    /// What separates this overload from the snapshot one. Handed the same
    /// arguments, the snapshot version reads every unmentioned card as departed
    /// and prunes it; a request that named one id must leave the rest alone.
    @Test("A request for one id never prunes the cards it did not mention")
    func subsetDoesNotPruneTheRest() {
        let previous: Set<String> = ["solar", "boiler", "washer"]

        let subset = SpotlightIndex.reconcile(
            previous: previous, reindexed: ["solar"], pruned: [], deleted: true, indexed: true
        )
        #expect(subset == ["solar", "boiler", "washer"])

        let snapshot = SpotlightIndex.reconcile(
            previous: previous, current: ["solar"], deleted: true, indexed: true
        )
        #expect(snapshot == ["solar"])
    }

    // MARK: - Helpers

    private func card(id: String) -> DashboardCard {
        DashboardCard(id: id, template: .summary, title: "Solar")
    }
}
