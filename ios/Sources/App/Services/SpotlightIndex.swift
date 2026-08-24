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
public struct DashboardCardEntity: AppEntity, IndexedEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Card")
    }

    public static var defaultQuery = DashboardCardEntityQuery()

    public var id: String

    @Property(title: "Title")
    public var title: String

    @Property(title: "Detail")
    public var detail: String?

    @Property(title: "Value")
    public var value: String?

    @Property(title: "Status")
    public var status: String

    @Property(title: "Last updated")
    public var updatedAt: Date

    public init(_ card: DashboardCard) {
        self.id = card.id
        self.title = card.title
        self.detail = card.subtitle
        // The unit belongs with the number for search: someone looking for
        // "3.4 kW" should not have to know the two are separate fields.
        self.value = [card.value, card.unit].compactMap { $0 }.joined(separator: " ")
        self.status = card.status.label
        self.updatedAt = card.updatedAt
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(value?.isEmpty == false ? value! : status)"
        )
    }

    public var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        attributes.contentDescription = [value, detail].compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        attributes.keywords = [title, status] + (detail.map { [$0] } ?? [])
        attributes.contentModificationDate = updatedAt
        return attributes
    }
}

/// `EntityStringQuery` rather than a plain `EntityQuery` because Siri resolves
/// the card in "what's the status of <card>" from what it heard, not from an
/// id. Without `entities(matching:)` the spoken half of `CardStatusIntent`
/// cannot bind its parameter at all.
public struct DashboardCardEntityQuery: EntityStringQuery {
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

    private static let looseComparison: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: looseComparison) == .orderedSame
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
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

    /// Makes the index match `cards`, adding what is new and removing what has
    /// gone. Safe to call on every cache write.
    public static func donate(_ cards: [DashboardCard]) {
        let keep = indexable(cards)
        let currentIds = Set(keep.map(\.id))

        // Siri's list of values for "what's the status of <card>" comes from
        // the same query as the index, so the set of answerable cards changing
        // is exactly this call. Refreshing here rather than at the eight call
        // sites keeps the two from drifting.
        ZeroZeroWidgetShortcuts.updateAppShortcutParameters()
        let previousIds = Set(UserDefaults.standard.stringArray(forKey: donatedIdsKey) ?? [])
        let departed = previousIds.subtracting(currentIds)

        UserDefaults.standard.set(Array(currentIds), forKey: donatedIdsKey)

        Task {
            let index = CSSearchableIndex.default()
            if !departed.isEmpty {
                do {
                    try await index.deleteAppEntities(
                        identifiedBy: Array(departed),
                        ofType: DashboardCardEntity.self
                    )
                } catch {
                    log.error("removing \(departed.count, privacy: .public) cards from Spotlight failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard !keep.isEmpty else { return }
            do {
                try await index.indexAppEntities(keep.map(DashboardCardEntity.init))
                log.info("donated \(keep.count, privacy: .public) cards to Spotlight")
            } catch {
                log.error("donating cards to Spotlight failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Everything out, for sign-out and for an explicit cache clear. A card
    /// left behind here would answer for a tenant nobody is signed into.
    public static func removeAll() {
        UserDefaults.standard.removeObject(forKey: donatedIdsKey)
        ZeroZeroWidgetShortcuts.updateAppShortcutParameters()
        Task {
            do {
                try await CSSearchableIndex.default()
                    .deleteAppEntities(ofType: DashboardCardEntity.self)
                log.info("cleared cards from Spotlight")
            } catch {
                log.error("clearing Spotlight failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
