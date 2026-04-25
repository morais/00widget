import WidgetKit
import Foundation

public struct CardTimelineEntry: TimelineEntry {
    public let date: Date
    public let card: DashboardCard?
    public let reason: CardFallbackView.Reason?

    public init(date: Date, card: DashboardCard?, reason: CardFallbackView.Reason? = nil) {
        self.date = date
        self.card = card
        self.reason = reason
    }
}

public struct CardTimelineProvider: AppIntentTimelineProvider {
    public typealias Intent = SelectCardIntent
    public typealias Entry = CardTimelineEntry

    public init() {}

    public func placeholder(in context: Context) -> CardTimelineEntry {
        CardTimelineEntry(date: Date(), card: SampleDataFactory.makeCards().first, reason: nil)
    }

    public func snapshot(for configuration: SelectCardIntent, in context: Context) async -> CardTimelineEntry {
        entry(for: configuration.card?.id)
    }

    public func timeline(for configuration: SelectCardIntent, in context: Context) async -> Timeline<CardTimelineEntry> {
        let entry = entry(for: configuration.card?.id)
        let refresh = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    private func entry(for cardId: String?) -> CardTimelineEntry {
        guard let cardId else {
            return CardTimelineEntry(date: Date(), card: nil, reason: .noCardSelected)
        }
        let cached = CardCache.load().cards
        guard let card = cached.first(where: { $0.id == cardId }) else {
            return CardTimelineEntry(date: Date(), card: nil, reason: .noCachedData)
        }
        if card.isStale {
            return CardTimelineEntry(date: Date(), card: card, reason: .stale(card.updatedAt))
        }
        return CardTimelineEntry(date: Date(), card: card, reason: nil)
    }
}
