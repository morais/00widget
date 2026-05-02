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

    public func entities(for identifiers: [CardEntity.ID]) async throws -> [CardEntity] {
        let cards = CardCache.load().cards
        return identifiers.compactMap { id in
            if id == Self.noneId { return CardEntity(id: id, title: "None") }
            guard let card = cards.first(where: { $0.id == id }) else { return nil }
            return CardEntity(id: card.id, title: card.title)
        }
    }

    public func suggestedEntities() async throws -> [CardEntity] {
        let cards = CardCache.load().cards.map { CardEntity(id: $0.id, title: $0.title) }
        return [CardEntity(id: Self.noneId, title: "None")] + cards
    }

    public func defaultResult() async -> CardEntity? {
        try? await suggestedEntities().first(where: { $0.id != Self.noneId })
    }
}

public struct SelectCardIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Select card"
    public static var description = IntentDescription("Choose which dashboard card to display.")

    @Parameter(title: "Card")
    public var card: CardEntity?

    public init() {}

    public init(card: CardEntity?) {
        self.card = card
    }
}
