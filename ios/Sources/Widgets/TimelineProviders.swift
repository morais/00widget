import WidgetKit
import Foundation
import os

public struct CardTimelineEntry: TimelineEntry {
    public let date: Date
    public let card: DashboardCard?
    public let density: CardRenderDensity
    public let reason: CardFallbackView.Reason?
    /// nil for placeholder and snapshot renders, which are previews rather
    /// than updates and have no trigger worth reporting.
    public let updateMark: WidgetUpdateMark?

    public init(
        date: Date,
        card: DashboardCard?,
        density: CardRenderDensity = .automatic,
        reason: CardFallbackView.Reason? = nil,
        updateMark: WidgetUpdateMark? = nil
    ) {
        self.date = date
        self.card = card
        self.density = density
        self.reason = reason
        self.updateMark = updateMark
    }

    public func marked(_ mark: WidgetUpdateMark) -> CardTimelineEntry {
        CardTimelineEntry(date: date, card: card, density: density, reason: reason, updateMark: mark)
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
        // Keyed by the card this widget shows, so two widgets do not overwrite
        // each other's history. Two showing the same card may share it: they
        // are pushed together anyway.
        let widgetKey = "card.\(configuration.card?.id ?? "default")"
        let startedAt = Date()
        let decision = WidgetRefreshPolicy.decide(for: widgetKey, now: startedAt)
        let diagnosticRunId = SharedSettings.showWidgetTimestamps
            ? WidgetTimelineDiagnostics.recordStart(widgetKey: widgetKey, at: startedAt)
            : nil
        Self.log.info("card timeline execution started for \(widgetKey, privacy: .public)")

        let refreshed = await refreshCacheIfPossible(reason: "timeline")
        let completedAt = Date()
        let source = WidgetUpdateSource.classify(
            wokenEarly: decision.wokenEarly,
            refreshSucceeded: refreshed,
            appReloadAt: SharedSettings.lastAppWidgetReloadAt,
            now: startedAt
        )
        let mark = WidgetUpdateMark(
            date: completedAt,
            source: source
        )
        if let diagnosticRunId {
            WidgetTimelineDiagnostics.recordCompletion(
                runId: diagnosticRunId,
                widgetKey: widgetKey,
                source: source,
                refreshSucceeded: refreshed,
                at: completedAt
            )
        }
        Self.log.info("card timeline execution completed for \(widgetKey, privacy: .public)")
        return Timeline(entries: [entry(for: configuration).marked(mark)], policy: .after(decision.next))
    }

    /// Returns whether this run actually reached the server. The caller needs
    /// that to tell a widget showing fresh state from one drawing its cache.
    @discardableResult
    private func refreshCacheIfPossible(reason: String) async -> Bool {
        guard let config = APIClientConfig.fromSettings() else {
            Self.log.info("skipping card refresh for \(reason, privacy: .public): API config unavailable")
            return false
        }

        do {
            let cards = try await APIClient(config: config).fetchCards()
            try CardCache.save(cards)
            Self.log.info("refreshed \(cards.count, privacy: .public) cards for \(reason, privacy: .public)")
            return true
        } catch {
            Self.log.error("card refresh failed for \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
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
