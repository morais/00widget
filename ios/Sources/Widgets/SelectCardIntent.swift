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

/// The grid gets its own entity type because an `AppEntity` has one fixed
/// `defaultQuery`. The single-card picker needs a synthetic "None" choice to
/// override its automatic first-card fallback; an empty grid selection already
/// means "follow the dashboard", so exposing that choice there is redundant.
public struct GridCardEntity: AppEntity {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Dashboard card")
    }

    public static var defaultQuery = GridCardEntityQuery()

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

private enum WidgetCardPickerSource {
    static var cards: [DashboardCard] {
        CardCache.cardsForWidgets()
    }

    /// A shared card and one of your own can carry the same title — ids are
    /// unique per tenant, not globally — so the picker has to say which is
    /// which. The rendered widget carries the link badge; this list is text.
    static func title(for card: DashboardCard) -> String {
        card.isFromGuestLink ? "\(card.title) (shared)" : card.title
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
        let cards = WidgetCardPickerSource.cards
        return identifiers.map { id in
            if id == Self.noneId { return CardEntity(id: id, title: "None") }
            guard let card = cards.first(where: { $0.id == id }) else {
                return CardEntity(id: id, title: id)
            }
            return CardEntity(id: card.id, title: WidgetCardPickerSource.title(for: card))
        }
    }

    public func suggestedEntities() async throws -> [CardEntity] {
        let cards = WidgetCardPickerSource.cards
            .map { CardEntity(id: $0.id, title: WidgetCardPickerSource.title(for: $0)) }
        return [CardEntity(id: Self.noneId, title: "None")] + cards
    }

    /// Deliberately no `defaultResult()`.
    ///
    /// The single-card timeline owns its automatic first-card fallback so nil
    /// remains distinct from the explicit "None" entity.
}

public struct GridCardEntityQuery: EntityQuery {
    public init() {}

    /// As with the single-card query, keep stored ids alive when a card is not
    /// currently cached. That lets the timeline distinguish a missing selected
    /// card from an unconfigured grid.
    public func entities(for identifiers: [GridCardEntity.ID]) async throws -> [GridCardEntity] {
        let cards = WidgetCardPickerSource.cards
        return identifiers.map { id in
            guard let card = cards.first(where: { $0.id == id }) else {
                return GridCardEntity(id: id, title: id)
            }
            return GridCardEntity(
                id: card.id,
                title: WidgetCardPickerSource.title(for: card)
            )
        }
    }

    public func suggestedEntities() async throws -> [GridCardEntity] {
        WidgetCardPickerSource.cards.map {
            GridCardEntity(id: $0.id, title: WidgetCardPickerSource.title(for: $0))
        }
    }
}

public struct SelectCardIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Select card"
    public static var description = IntentDescription("Choose which dashboard card to display.")

    @Parameter(title: "Card")
    public var card: CardEntity?

    @Parameter(title: "Display density", default: .automatic)
    public var density: WidgetCardDensity

    // Deliberately no status filter. This widget shows one named card, so a
    // filter can only ever blank it — the reader already knows the status of
    // the card they picked. Filtering belongs to the grid, where it chooses
    // which of several cards get the cells.

    public init() {
        self.density = .automatic
    }

    public init(card: CardEntity?) {
        self.card = card
        self.density = .automatic
    }
}
