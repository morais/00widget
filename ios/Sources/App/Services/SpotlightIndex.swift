import Foundation
import AppIntents
import CoreSpotlight
import os

/// A published card as Spotlight and Siri see it.
///
/// Deliberately separate from `CardEntity`, which lives in `Sources/Widgets`
/// and exists to fill the widget configuration picker. The two have different
/// jobs — a picker row needs an id and a title, a searchable record needs
/// properties worth matching against — and `CardEntity` sits on the AppIntents
/// rehydration path this repo already documents as fragile. Indexing is the
/// app's job alone, so this type lives in the app target and is never compiled
/// into the widget extension.
public struct DashboardCardEntity: AppEntity, IndexedEntity, URLRepresentableEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Card")
    }

    public static var defaultQuery = DashboardCardEntityQuery()

    public var id: String

    // Three of these carry an `indexingKey`, which is what connects the
    // AppIntents property to the Spotlight attribute of the same meaning.
    // Without it the two layers are unrelated — the properties feed parameter
    // resolution, the attribute set feeds Spotlight, and nothing tells the
    // index what a field *is*. A bound property is structure iOS 27's semantic
    // layer can reason over; an unbound one is prose in a blob of text.

    @Property(title: "Title", indexingKey: \.title)
    public var title: String

    @Property(title: "Detail", indexingKey: \.contentDescription)
    public var detail: String?

    // `value` and `status` stay unbound: CSSearchableItemAttributeSet has no
    // attribute that means "what this thing currently reads", and binding them
    // to an unrelated one would be worse than leaving them out. They reach
    // Spotlight as keywords instead, which is a search term rather than a
    // claim about meaning.
    @Property(title: "Value")
    public var value: String?

    @Property(title: "Status")
    public var status: String

    // The three groupings a person actually asks about, as Bools rather than
    // one grouping property. They overlap — a paused washer needs attention
    // *and* is active — so there is no single value a card could hold, and a
    // partition would have to lie about one of them.
    @Property(title: "Needs attention")
    public var needsAttention: Bool

    @Property(title: "Active")
    public var isActive: Bool

    @Property(title: "Healthy")
    public var isHealthy: Bool

    @Property(title: "Last updated", indexingKey: \.contentModificationDate)
    public var updatedAt: Date

    public init(_ card: DashboardCard) {
        self.id = card.id
        self.title = card.title
        self.detail = card.subtitle
        // The unit belongs with the number for search: someone looking for
        // "3.4 kW" should not have to know the two are separate fields.
        self.value = [card.value, card.unit].compactMap { $0 }.joined(separator: " ")
        self.status = card.status.label
        self.needsAttention = card.status.needsAttention
        self.isActive = card.status.isActive
        self.isHealthy = card.status.isHealthy
        self.updatedAt = card.updatedAt
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(value?.isEmpty == false ? value! : status)"
        )
    }

    /// Where a Spotlight result goes when the system opens it as a URL rather
    /// than through `OpenCardIntent`. Both land on the same route.
    ///
    /// The scheme is spelled out rather than interpolated from
    /// `ZeroZeroWidgetInternalLink.scheme`: this literal is a compile-time
    /// template whose only permitted interpolation is the framework's own
    /// `.id` token, so a runtime string cannot appear in it.
    /// `ZeroZeroWidgetInternalLinkTests` pins the two together.
    public static var urlRepresentation: URLRepresentation {
        "zerozerowidget://card/\(.id)"
    }

    /// The attributes still have to be set by hand. `indexingKey` declares what
    /// a property *means*; it does not populate anything here.
    ///
    /// Measured, because it is easy to assume otherwise and the assumption
    /// fails silently: with all three keys bound, `defaultAttributeSet` comes
    /// back carrying only `title` — and removing `indexingKey: \.title` leaves
    /// that title exactly where it was, because it is derived from
    /// `displayRepresentation`. So a binding-only version of this type would
    /// have shipped an index with no description and no modification date at
    /// all. The bindings are still what iOS 27's semantic layer reads; they are
    /// simply not the same channel as the attribute set.
    ///
    /// Note what is deliberately *not* here: the card's current value. Spotlight
    /// renders `contentDescription` as the result's subtitle, and the index goes
    /// stale whenever the widget extension refreshes the cache with the app
    /// closed — so a number there is read confidently while being an unknown
    /// number of hours old, under a `contentModificationDate` that looks fresh.
    /// As a keyword it stays searchable without being asserted.
    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = detail?.isEmpty == false ? detail : nil
        attributes.contentModificationDate = updatedAt
        attributes.keywords = [title, status, value, detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return attributes
    }
}

/// `EntityStringQuery` rather than a plain `EntityQuery` because Siri resolves
/// the card in "what's the status of <card>" from what it heard, not from an
/// id. Without `entities(matching:)` the spoken half of `CardStatusIntent`
/// cannot bind its parameter at all.
public struct DashboardCardEntityQuery: EntityStringQuery, EntityPropertyQuery {
    public init() {}

    public func entities(for identifiers: [DashboardCardEntity.ID]) async throws -> [DashboardCardEntity] {
        let cards = SpotlightIndex.indexable(CardCache.load().cards)
        return identifiers.compactMap { id in
            cards.first { $0.id == id }.map(DashboardCardEntity.init)
        }
    }

    public func entities(matching string: String) async throws -> [DashboardCardEntity] {
        DashboardCardEntityQuery.matches(string, in: SpotlightIndex.indexable(CardCache.load().cards))
            .map(DashboardCardEntity.init)
    }

    public func suggestedEntities() async throws -> [DashboardCardEntity] {
        SpotlightIndex.indexable(CardCache.load().cards).map(DashboardCardEntity.init)
    }

    // MARK: - EntityPropertyQuery

    /// What a comparator compiles down to: a test one card either passes or
    /// fails.
    ///
    /// The framework wants a mapping type it can hand back as an array, and a
    /// closure is the honest one here — the cards are already in memory, so
    /// there is no store to translate a predicate for.
    public struct CardPredicate {
        let matches: (DashboardCard) -> Bool
    }

    public typealias ComparatorMappingType = CardPredicate

    public static var properties = QueryProperties {
        Property(\DashboardCardEntity.$needsAttention) {
            EqualToComparator { wanted in CardPredicate { $0.status.needsAttention == wanted } }
        }
        Property(\DashboardCardEntity.$isActive) {
            EqualToComparator { wanted in CardPredicate { $0.status.isActive == wanted } }
        }
        Property(\DashboardCardEntity.$isHealthy) {
            EqualToComparator { wanted in CardPredicate { $0.status.isHealthy == wanted } }
        }
        Property(\DashboardCardEntity.$status) {
            EqualToComparator { wanted in
                CardPredicate { $0.status.label.compare(wanted, options: looseComparison) == .orderedSame }
            }
            NotEqualToComparator { wanted in
                CardPredicate { $0.status.label.compare(wanted, options: looseComparison) != .orderedSame }
            }
        }
        Property(\DashboardCardEntity.$title) {
            ContainsComparator { text in CardPredicate { contains($0.title, text) } }
            EqualToComparator { text in
                CardPredicate { $0.title.compare(text, options: looseComparison) == .orderedSame }
            }
        }
        Property(\DashboardCardEntity.$updatedAt) {
            GreaterThanOrEqualToComparator { date in CardPredicate { $0.updatedAt >= date } }
            LessThanOrEqualToComparator { date in CardPredicate { $0.updatedAt <= date } }
        }
    }

    /// Names the Find action Shortcuts generates from the declarations above.
    /// Without it the action is titled after the type and says nothing about
    /// what it can be asked.
    public static var findIntentDescription = IntentDescription(
        "Finds published cards by status, title, or when they last changed.",
        categoryName: "Cards"
    )

    public static var sortingOptions = SortingOptions {
        SortableBy(\DashboardCardEntity.$title)
        SortableBy(\DashboardCardEntity.$updatedAt)
        SortableBy(\DashboardCardEntity.$status)
    }

    public func entities(
        matching comparators: [CardPredicate],
        mode: ComparatorMode,
        sortedBy: [EntityQuerySort<DashboardCardEntity>],
        limit: Int?
    ) async throws -> [DashboardCardEntity] {
        DashboardCardEntityQuery.filter(
            SpotlightIndex.indexable(CardCache.load().cards),
            matching: comparators,
            mode: mode,
            sortedBy: sortedBy.compactMap(CardSortOrder.init),
            limit: limit
        )
        .map(DashboardCardEntity.init)
    }

    /// One sort the caller asked for, in terms this file can construct.
    ///
    /// `EntityQuerySort` has no public initialiser, so translating at the
    /// boundary is what lets the ordering rules be tested at all — otherwise
    /// the only way to exercise them is through the AppIntents runtime.
    struct CardSortOrder: Equatable {
        enum Field { case title, status, updatedAt }

        let field: Field
        let ascending: Bool

        init(field: Field, ascending: Bool) {
            self.field = field
            self.ascending = ascending
        }

        /// Returns nil for a sortable property this build does not know how to
        /// order, so an unrecognised one leaves the caller's order alone rather
        /// than imposing an arbitrary one.
        init?(_ sort: EntityQuerySort<DashboardCardEntity>) {
            switch sort.by {
            case \DashboardCardEntity.$title: field = .title
            case \DashboardCardEntity.$status: field = .status
            case \DashboardCardEntity.$updatedAt: field = .updatedAt
            default: return nil
            }
            ascending = sort.order == .ascending
        }
    }

    /// Pure, so the predicate and ordering semantics are testable without the
    /// AppIntents runtime — which is much of the reason this query was worth
    /// conforming.
    static func filter(
        _ cards: [DashboardCard],
        matching comparators: [CardPredicate],
        mode: ComparatorMode,
        sortedBy: [CardSortOrder],
        limit: Int?
    ) -> [DashboardCard] {
        // An empty comparator list means "everything", under either mode. `.or`
        // over nothing is vacuously false, which would answer a Find action
        // carrying no filters with an empty list — a wrong answer to a question
        // nobody asked.
        var result = comparators.isEmpty ? cards : cards.filter { card in
            switch mode {
            case .and: return comparators.allSatisfy { $0.matches(card) }
            case .or: return comparators.contains { $0.matches(card) }
            @unknown default: return comparators.allSatisfy { $0.matches(card) }
            }
        }

        // Applied in reverse so the first sort the caller listed ends up the
        // outermost one, which is what chaining stable sorts requires.
        for sort in sortedBy.reversed() {
            result = stableSorted(result, by: sort)
        }

        if let limit, result.count > limit {
            result = Array(result.prefix(limit))
        }
        return result
    }

    private static func stableSorted(
        _ cards: [DashboardCard],
        by sort: CardSortOrder
    ) -> [DashboardCard] {
        // Swift's sort is not stable, so equal elements are tie-broken on their
        // arrival index rather than trusting it to leave them alone. Without
        // that, a second sort silently scrambles what the first one decided.
        cards.enumerated().sorted { lhs, rhs in
            let order: ComparisonResult
            switch sort.field {
            case .title:
                order = lhs.element.title.compare(rhs.element.title, options: looseComparison)
            case .status:
                order = lhs.element.status.label.compare(rhs.element.status.label, options: looseComparison)
            case .updatedAt:
                order = compare(lhs.element.updatedAt, rhs.element.updatedAt)
            }
            if order == .orderedSame { return lhs.offset < rhs.offset }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
        .map(\.element)
    }

    private static func compare(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// Title first, then subtitle, with an exact title winning outright.
    ///
    /// Speech arrives cased and accented however the recogniser felt, so the
    /// comparison ignores both. Substring rather than equality because titles
    /// are producer-chosen and usually longer than what anyone says out loud —
    /// "washer" should find "Washer (kitchen)" — and an exact match is checked
    /// first so a card titled "Solar" is not buried by "Solar forecast".
    static func matches(_ query: String, in cards: [DashboardCard]) -> [DashboardCard] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        let exact = cards.filter { equal($0.title, needle) }
        guard exact.isEmpty else { return exact }

        let byTitle = cards.filter { contains($0.title, needle) }
        guard byTitle.isEmpty else { return byTitle }

        return cards.filter { contains($0.subtitle ?? "", needle) }
    }

    static let looseComparison: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: looseComparison) == .orderedSame
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: looseComparison) != nil
    }
}

/// Keeps Spotlight's view of the tenant's cards in step with the cache.
///
/// The app owns this and the widget extension must not: `CardCache.save` is
/// called from both timeline providers, so donating from there would re-index
/// on every push.
public enum SpotlightIndex {
    private static let log = Logger(subsystem: "com.example.zerozerowidget", category: "Spotlight")

    /// The ids currently believed to be in the index. App-scoped rather than
    /// App Group, because only the app ever donates, and it is what lets a
    /// removal be a diff rather than a full rebuild — a rebuild would empty
    /// Spotlight for as long as the re-index takes.
    private static let donatedIdsKey = "zw.spotlight.donatedCardIds"

    /// Which cards are ours to put in a system-wide index.
    ///
    /// Samples are demo fixtures generated on-device for someone who has never
    /// signed in. Indexing them would answer "what's my solar output" for a
    /// person with no solar panels, and the SAMPLE badge that makes them
    /// honest in the app cannot follow a card into Spotlight.
    ///
    /// Guest-link and shared cards belong to another tenant. They are
    /// read-only, their owner can revoke them at any moment, and a local index
    /// would outlive that consent — Siri would keep answering from a cache
    /// after access was withdrawn.
    public static func indexable(_ cards: [DashboardCard]) -> [DashboardCard] {
        cards.filter { !$0.isSample && !$0.isFromGuestLink && $0.sharedBy == nil }
    }

    /// What the stored set should become, given what it held, what the snapshot
    /// holds, and which of the two index operations actually succeeded.
    ///
    /// The whole point of the type is that a failure is not a state change. The
    /// stored set is a claim about what is *in Spotlight*, not a copy of the
    /// last snapshot, and writing the snapshot into it unconditionally — which
    /// is what this code used to do, before the `Task` had even run — made a
    /// throw indistinguishable from a success.
    ///
    /// The half that mattered was the delete. Departed ids were dropped from
    /// the stored set whether or not `deleteAppEntities` succeeded, so a failed
    /// delete left those cards in Spotlight with nothing left tracking them:
    /// no later `donate` could compute them as departed again, and they
    /// survived until the next `removeAll()` — that is, until sign-out. That is
    /// the path a card deletion travels, which makes it the half with a privacy
    /// consequence rather than a cosmetic one.
    static func reconcile(
        previous: Set<String>,
        current: Set<String>,
        deleted: Bool,
        indexed: Bool
    ) -> Set<String> {
        var believed = previous
        if deleted { believed.subtract(previous.subtracting(current)) }
        if indexed { believed.formUnion(current) }
        return believed
    }

    /// Makes the index match `cards`, adding what is new and removing what has
    /// gone. Safe to call on every cache write.
    ///
    /// `defaults` is injectable so the diff-and-prune path is testable; nothing
    /// in the app passes anything but the default.
    public static func donate(_ cards: [DashboardCard], defaults: UserDefaults = .standard) {
        let keep = indexable(cards)
        let currentIds = Set(keep.map(\.id))

        // Siri's list of values for "what's the status of <card>" comes from
        // the same query as the index, so the set of answerable cards changing
        // is exactly this call. Refreshing here rather than at the eight call
        // sites keeps the two from drifting.
        ZeroZeroWidgetShortcuts.updateAppShortcutParameters()
        let previousIds = Set(defaults.stringArray(forKey: donatedIdsKey) ?? [])
        let departed = previousIds.subtracting(currentIds)

        Task {
            let index = CSSearchableIndex.default()
            // An operation with nothing to do counts as done: there is no
            // outstanding work for the bookkeeping to be pessimistic about.
            var deleted = departed.isEmpty
            var indexed = keep.isEmpty

            if !departed.isEmpty {
                do {
                    try await index.deleteAppEntities(
                        identifiedBy: Array(departed),
                        ofType: DashboardCardEntity.self
                    )
                    deleted = true
                } catch {
                    log.error("removing \(departed.count, privacy: .public) cards from Spotlight failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            if !keep.isEmpty {
                do {
                    try await index.indexAppEntities(keep.map(DashboardCardEntity.init))
                    indexed = true
                    log.info("donated \(keep.count, privacy: .public) cards to Spotlight")
                } catch {
                    log.error("donating cards to Spotlight failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            // Bookkeeping last, and only for the halves that actually ran.
            let believed = reconcile(
                previous: previousIds,
                current: currentIds,
                deleted: deleted,
                indexed: indexed
            )
            defaults.set(Array(believed), forKey: donatedIdsKey)
        }
    }

    /// Everything out, for sign-out and for an explicit cache clear. A card
    /// left behind here would answer for a tenant nobody is signed into.
    ///
    /// The stored set is cleared only if the delete succeeded, for the same
    /// reason as `donate`: forgetting the ids on a failure orphans them
    /// permanently, whereas keeping them lets the next `donate` — including
    /// one under a different account — compute them as departed and try again.
    public static func removeAll(defaults: UserDefaults = .standard) {
        ZeroZeroWidgetShortcuts.updateAppShortcutParameters()
        Task {
            do {
                try await CSSearchableIndex.default()
                    .deleteAppEntities(ofType: DashboardCardEntity.self)
                defaults.removeObject(forKey: donatedIdsKey)
                log.info("cleared cards from Spotlight")
            } catch {
                log.error("clearing Spotlight failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
