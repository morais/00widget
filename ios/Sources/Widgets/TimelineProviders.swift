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
        let refresh = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(refresh))
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
        let cached = CardCache.load().cards

        guard let cardId = configuration.card?.id else {
            if filter == .all {
                return CardTimelineEntry(date: Date(), card: nil, density: density, reason: .noCardSelected)
            }
            guard let card = cached.first(where: { filter.includes($0.status) }) else {
                return CardTimelineEntry(date: Date(), card: nil, density: density, reason: .filtered(filter.fallbackLabel))
            }
            return CardTimelineEntry(date: Date(), card: card, density: density, reason: card.isStale ? .stale(card.updatedAt) : nil)
        }

        guard let card = cached.first(where: { $0.id == cardId }) else {
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
