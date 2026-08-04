import AppIntents
import WidgetKit
import Foundation

public struct CardEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Dashboard card")
    }

    public static var defaultQuery = CardEntityQuery()

    public var id: String
    public var title: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct CardEntityQuery: EntityQuery {
    public static let noneId = "__none__"

    public init() {}

    /// Rehydrates the card a widget's stored configuration points at.
    ///
    /// Never drops an identifier. Returning nothing for an id the cache does not
    /// currently hold leaves the parameter unresolved, and an unresolved
    /// parameter is indistinguishable from an unconfigured widget — so a widget
    /// whose card was deleted, or that woke while the cache was unavailable,
    /// would stop reporting which card it was actually set to. Keeping the id
    /// alive lets `CardTimelineProvider` say `.noCachedData` about the right
    /// card instead.
    public func entities(for identifiers: [CardEntity.ID]) async throws -> [CardEntity] {
        let cards = CardCache.load().cards
        return identifiers.map { id in
            if id == Self.noneId { return CardEntity(id: id, title: "None") }
            guard let card = cards.first(where: { $0.id == id }) else {
                return CardEntity(id: id, title: id)
            }
            return CardEntity(id: card.id, title: card.title)
        }
    }

    public func suggestedEntities() async throws -> [CardEntity] {
        let cards = CardCache.load().cards.map { CardEntity(id: $0.id, title: $0.title) }
        return [CardEntity(id: Self.noneId, title: "None")] + cards
    }

    // Deliberately no `defaultResult()`.
    //
    // It used to return the first cached card, which meant any parameter
    // AppIntents could not resolve silently became "whatever card happens to be
    // first" — rendering another card's live data in a widget the user had set
    // to something else. That is indistinguishable from a correctly configured
    // widget, so the failure is invisible: a widget set to Car shows Solar and
    // looks right. An unconfigured or unresolvable widget must say so, which is
    // what `.noCardSelected` ("Pick a card") is for.
}

public struct SelectCardIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Select card"
    public static var description = IntentDescription("Choose which dashboard card to display.")

    @Parameter(title: "Card")
    public var card: CardEntity?

    @Parameter(title: "Display density", default: .automatic)
    public var density: WidgetCardDensity

    @Parameter(title: "Show status", default: .all)
    public var statusFilter: WidgetStatusFilter

    public init() {
        self.density = .automatic
        self.statusFilter = .all
    }

    public init(card: CardEntity?) {
        self.card = card
        self.density = .automatic
        self.statusFilter = .all
    }
}
