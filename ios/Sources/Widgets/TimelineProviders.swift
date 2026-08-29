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

        await repairPushSubscription(for: configuration)

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

    private func repairPushSubscription(for configuration: SelectCardIntent) async {
        let subscription: WidgetPushSubscription
        if let cardId = configuration.card?.id {
            guard cardId != CardEntityQuery.noneId else { return }
            subscription = WidgetPushSubscription(
                widgetKind: ZeroZeroWidgetConstants.WidgetKinds.card,
                cardIds: [cardId]
            )
        } else {
            subscription = WidgetPushSubscription(
                widgetKind: ZeroZeroWidgetConstants.WidgetKinds.card,
                allCards: true
            )
        }
        guard let snapshot = WidgetPushTokenStore.mergeSubscription(subscription) else { return }
        do {
            _ = try await WidgetPushTokenRegistrar.register(snapshot)
        } catch {
            Self.log.error(
                "card timeline push registration repair failed: \(error.localizedDescription, privacy: .public)"
            )
        }
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
        let cached = CardCache.cardsForWidgets()

        // `CardEntityQuery.defaultResult()` normally gives a new widget a
        // concrete card id. If no card existed when the widget was added, keep
        // it unconfigured rather than recalculating the first card on every
        // render. Once cards arrive it can ask the person to make a deliberate
        // selection.
        guard let selection = configuration.card?.id else {
            let reason: CardFallbackView.Reason = cached.isEmpty ? .noCachedData : .noCardSelected
            return CardTimelineEntry(date: Date(), card: nil, density: density, reason: reason)
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
        if card.isStale {
            return CardTimelineEntry(date: Date(), card: card, density: density, reason: .stale(card.updatedAt))
        }
        return CardTimelineEntry(date: Date(), card: card, density: density, reason: nil)
    }
}
