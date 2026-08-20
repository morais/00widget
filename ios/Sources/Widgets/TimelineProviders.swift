import WidgetKit
import Foundation
import os

public struct CardTimelineEntry: TimelineEntry {
    public let date: Date
    public let card: DashboardCard?
    public let density: CardRenderDensity
    public let reason: CardFallbackView.Reason?

    public init(date: Date, card: DashboardCard?, density: CardRenderDensity = .automatic, reason: CardFallbackView.Reason? = nil) {
        self.date = date
        self.card = card
        self.density = density
        self.reason = reason
    }
}

public struct CardTimelineProvider: AppIntentTimelineProvider {
    public typealias Intent = SelectCardIntent
    public typealias Entry = CardTimelineEntry

    private static let log = Logger(subsystem: "com.example.zerozerowidget", category: "Timeline")

    public init() {}

    public func placeholder(in context: Context) -> CardTimelineEntry {
        CardTimelineEntry(date: Date(), card: SampleDataFactory.makeCards().first, reason: nil)
    }

    public func snapshot(for configuration: SelectCardIntent, in context: Context) async -> CardTimelineEntry {
        await refreshCacheIfPossible(reason: "snapshot")
        return entry(for: configuration)
    }

    public func timeline(for configuration: SelectCardIntent, in context: Context) async -> Timeline<CardTimelineEntry> {
        await refreshCacheIfPossible(reason: "timeline")
        let entry = entry(for: configuration)
        // Keyed by the card this widget shows, so two widgets do not overwrite
        // each other's history. Two showing the same card may share it: they
        // are pushed together anyway.
        let widgetKey = "card.\(configuration.card?.id ?? "default")"
        return Timeline(entries: [entry], policy: .after(WidgetRefreshPolicy.next(for: widgetKey)))
    }

    private func refreshCacheIfPossible(reason: String) async {
        guard let config = APIClientConfig.fromSettings() else {
            Self.log.info("skipping card refresh for \(reason, privacy: .public): API config unavailable")
            return
        }

        do {
            let cards = try await APIClient(config: config).fetchCards()
            try CardCache.save(cards)
            Self.log.info("refreshed \(cards.count, privacy: .public) cards for \(reason, privacy: .public)")
        } catch {
            Self.log.error("card refresh failed for \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func entry(for configuration: SelectCardIntent) -> CardTimelineEntry {
        let density = configuration.density.renderDensity
        let filter = configuration.statusFilter
        let cached = CardCache.cardsForWidgets()

        // A widget nobody has configured yet renders the first card that passes
        // its filter, so a placement made from the gallery shows something
        // instead of "Pick a card". This lives here rather than in
        // CardEntityQuery.defaultResult() because that query also backs the
        // grid widget's four slots, where a single default is the same card
        // four times.
        guard let selection = configuration.card?.id else {
            guard let card = cached.first(where: { filter.includes($0.status) }) else {
                let reason: CardFallbackView.Reason = cached.isEmpty ? .noCachedData : .filtered(filter.fallbackLabel)
                return CardTimelineEntry(date: Date(), card: nil, density: density, reason: reason)
            }
            return CardTimelineEntry(date: Date(), card: card, density: density, reason: card.isStale ? .stale(card.updatedAt) : nil)
        }

        // "None" is a real pick in the card list, and the only way to ask for an
        // empty widget now that an unconfigured one defaults to a card. Honour
        // it instead of treating it as a card id the cache has lost.
        guard selection != CardEntityQuery.noneId else {
            return CardTimelineEntry(date: Date(), card: nil, density: density, reason: .noCardSelected)
        }
        guard let card = cached.first(where: { $0.id == selection }) else {
            return CardTimelineEntry(date: Date(), card: nil, density: density, reason: .noCachedData)
        }
        guard filter.includes(card.status) else {
            return CardTimelineEntry(date: Date(), card: nil, density: density, reason: .filtered(filter.fallbackLabel))
        }
        if card.isStale {
            return CardTimelineEntry(date: Date(), card: card, density: density, reason: .stale(card.updatedAt))
        }
        return CardTimelineEntry(date: Date(), card: card, density: density, reason: nil)
    }
}
