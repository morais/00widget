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
        let cards = CardCache.cardsForWidgets()
        return identifiers.map { id in
            if id == Self.noneId { return CardEntity(id: id, title: "None") }
            guard let card = cards.first(where: { $0.id == id }) else {
                return CardEntity(id: id, title: id)
            }
            return CardEntity(id: card.id, title: Self.pickerTitle(for: card))
        }
    }

    public func suggestedEntities() async throws -> [CardEntity] {
        let cards = CardCache.cardsForWidgets()
            .map { CardEntity(id: $0.id, title: Self.pickerTitle(for: $0)) }
        return [CardEntity(id: Self.noneId, title: "None")] + cards
    }

    /// A shared card and one of your own can carry the same title — ids are
    /// unique per tenant, not globally — so the picker has to say which is
    /// which. The rendered widget carries the link badge; this list is text.
    private static func pickerTitle(for card: DashboardCard) -> String {
        card.isFromGuestLink ? "\(card.title) (shared)" : card.title
    }

    /// Deliberately no `defaultResult()`.
    ///
    /// A freshly placed widget should render a card rather than "Pick a card",
    /// but this query cannot be where that is decided: it backs all four slots
    /// of the grid widget as well, so one default for every slot is the same
    /// card four times. The default is a property of the widget, not of the
    /// card list, so each timeline provider picks its own — one card for
    /// `CardTimelineProvider`, four distinct ones for
    /// `CardGridTimelineProvider`.
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
