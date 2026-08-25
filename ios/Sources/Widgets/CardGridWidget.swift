import WidgetKit
import SwiftUI
import AppIntents
import Foundation
import os

/// Only the small family asks this: it is a single tap target covering every
/// cell, so the whole question is whether that tap opens the app or the card
/// the grid leads with.
///
/// Deliberately not one case per cell. Naming cells stopped being possible
/// when the count became dynamic — a grid draws as many cells as it has cards
/// — and "the second card" is a weak thing to ask a reader to choose when
/// priority decides which card that is and the producer can change it.
public enum CardGridTapTarget: String, AppEnum {
    case app
    case first

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Tap action")
    }

    public static var caseDisplayRepresentations: [CardGridTapTarget: DisplayRepresentation] = [
        .app: DisplayRepresentation(title: "Open the app"),
        .first: DisplayRepresentation(title: "Open the first card")
    ]

    var cardIndex: Int? {
        switch self {
        case .app: return nil
        case .first: return 0
        }
    }
}

public struct SelectGridCardsIntent: WidgetConfigurationIntent {
    /// How many cells the grid draws on the ordinary families. A selection may
    /// be longer: the widget shows the highest-priority `maxCards` of whatever
    /// passes the status filter, so picking eight and filtering to "needs
    /// attention" is a meaningful configuration rather than a mistake.
    public static let maxCards = 4

    /// The double-width canvases hold twice as many cells legibly — this is
    /// the first family where the grid reads as a wall dashboard rather than a
    /// tile.
    public static let extraLargeMaxCards = 8

    /// Cells drawn on `family`.
    ///
    /// Capacity is a *rendering* decision and nothing more. The push
    /// subscription is driven by the selection — or by `allCards` when the
    /// selection is empty — never by how many cells get drawn, so a roomier
    /// grid draws more of the cards it already caches without subscribing to
    /// anything new. It therefore costs no additional WidgetKit reload budget,
    /// which is the constraint that would otherwise govern this.
    public static func capacity(for family: WidgetFamily) -> Int {
        if FullPageWidgetFamily.contains(family) { return extraLargeMaxCards }
        return family == .systemExtraLarge ? extraLargeMaxCards : maxCards
    }

    public static var title: LocalizedStringResource = "Select cards"
    public static var description = IntentDescription(
        "Choose which cards this grid may show. The highest-priority four appear — eight on the largest sizes — and picking none follows your whole dashboard."
    )

    /// A set, not four ordered slots. Ordering comes from card priority, which
    /// the producer controls and the cache already arrives sorted by — see
    /// `entry(for:)`.
    ///
    /// Empty is meaningful and is the default: the grid follows the top cards
    /// of the dashboard as they change. Seeding this with today's top four
    /// instead, which the four-slot version did, froze a new placement to
    /// whatever happened to be cached when it was placed.
    ///
    /// Optional because a `WidgetConfigurationIntent` refuses to export
    /// AppIntents metadata for a non-optional parameter of any type. Nil and
    /// empty mean the same thing here.
    @Parameter(title: "Cards")
    public var cards: [CardEntity]?

    @Parameter(title: "On compact tap", default: .app)
    public var compactTapTarget: CardGridTapTarget

    @Parameter(title: "Display density", default: .automatic)
    public var density: WidgetCardDensity

    @Parameter(title: "Show statuses", default: .all)
    public var statusFilter: WidgetStatusFilter

    public init() {
        self.cards = nil
        self.compactTapTarget = .app
        self.density = .automatic
        self.statusFilter = .all
    }

    /// The picker is shared with the single-card widget, whose list carries a
    /// "None" row so a placement can be deliberately blank. A set has no use
    /// for it — empty already says that — so drop it wherever it is read.
    var selectedCardIds: [String] {
        (cards ?? []).map(\.id).filter { $0 != CardEntityQuery.noneId }
    }
}

public struct CardGridEntry: TimelineEntry {
    public let date: Date
    /// The cards to draw, in order, with nothing missing between them: the grid
    /// lays out as many cells as there are cards rather than padding to four.
    public let cards: [DashboardCard]
    public let reason: CardFallbackView.Reason?
    public let compactTapTarget: CardGridTapTarget
    public let density: WidgetCardDensity
    public let statusFilter: WidgetStatusFilter
    /// nil for placeholder and snapshot renders. See `CardTimelineEntry`.
    public let updateMark: WidgetUpdateMark?

    public init(
        date: Date,
        cards: [DashboardCard],
        reason: CardFallbackView.Reason? = nil,
        compactTapTarget: CardGridTapTarget,
        density: WidgetCardDensity,
        statusFilter: WidgetStatusFilter,
        updateMark: WidgetUpdateMark? = nil
    ) {
        self.date = date
        self.cards = cards
        self.reason = reason
        self.compactTapTarget = compactTapTarget
        self.density = density
        self.statusFilter = statusFilter
        self.updateMark = updateMark
    }

    public func marked(_ mark: WidgetUpdateMark) -> CardGridEntry {
        CardGridEntry(
            date: date,
            cards: cards,
            reason: reason,
            compactTapTarget: compactTapTarget,
            density: density,
            statusFilter: statusFilter,
            updateMark: mark
        )
    }
}

public struct CardGridTimelineProvider: AppIntentTimelineProvider {
    public typealias Intent = SelectGridCardsIntent
    public typealias Entry = CardGridEntry

    private static let log = Logger(subsystem: "com.example.zerozerowidget", category: "Timeline")

    public init() {}

    public func placeholder(in context: Context) -> CardGridEntry {
        return CardGridEntry(
            date: Date(),
            cards: Array(SampleDataFactory.makeCards().prefix(SelectGridCardsIntent.capacity(for: context.family))),
            compactTapTarget: .app,
            density: .automatic,
            statusFilter: .all
        )
    }

    public func snapshot(for configuration: SelectGridCardsIntent, in context: Context) async -> CardGridEntry {
        await refreshCacheIfPossible(reason: "snapshot")
        return entry(for: configuration, capacity: SelectGridCardsIntent.capacity(for: context.family))
    }

    public func timeline(for configuration: SelectGridCardsIntent, in context: Context) async -> Timeline<CardGridEntry> {
        // Keyed by what this placement shows, so two grids do not overwrite
        // each other's history.
        let widgetKey = "grid.\(configuration.selectedCardIds.joined(separator: "+"))"
        let startedAt = Date()
        let decision = WidgetRefreshPolicy.decide(for: widgetKey, now: startedAt)
        let diagnosticRunId = SharedSettings.showWidgetTimestamps
            ? WidgetTimelineDiagnostics.recordStart(widgetKey: widgetKey, at: startedAt)
            : nil
        Self.log.info("grid timeline execution started for \(widgetKey, privacy: .public)")

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
        Self.log.info("grid timeline execution completed for \(widgetKey, privacy: .public)")
        let capacity = SelectGridCardsIntent.capacity(for: context.family)
        return Timeline(entries: [entry(for: configuration, capacity: capacity).marked(mark)], policy: .after(decision.next))
    }

    private func repairPushSubscription(for configuration: SelectGridCardsIntent) async {
        let cardIds = configuration.selectedCardIds
        let subscription: WidgetPushSubscription
        if cardIds.isEmpty {
            // Following the dashboard rather than a set: any card can change
            // which four this grid draws.
            subscription = WidgetPushSubscription(
                widgetKind: ZeroZeroWidgetConstants.WidgetKinds.cardGrid,
                allCards: true
            )
        } else {
            subscription = WidgetPushSubscription(
                widgetKind: ZeroZeroWidgetConstants.WidgetKinds.cardGrid,
                cardIds: cardIds
            )
        }
        guard let snapshot = WidgetPushTokenStore.mergeSubscription(subscription) else { return }
        do {
            _ = try await WidgetPushTokenRegistrar.register(snapshot)
        } catch {
            Self.log.error(
                "grid timeline push registration repair failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// See `CardTimelineProvider.refreshCacheIfPossible(reason:)`.
    @discardableResult
    private func refreshCacheIfPossible(reason: String) async -> Bool {
        guard let config = APIClientConfig.fromSettings() else {
            Self.log.info("skipping grid refresh for \(reason, privacy: .public): API config unavailable")
            return false
        }
        do {
            let cards = try await APIClient(config: config).fetchCards()
            try CardCache.save(cards)
            Self.log.info("refreshed \(cards.count, privacy: .public) cards for \(reason, privacy: .public)")
            return true
        } catch {
            Self.log.error("grid refresh failed for \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func entry(for configuration: SelectGridCardsIntent, capacity: Int) -> CardGridEntry {
        let filter = configuration.statusFilter
        let cached = CardCache.cardsForWidgets()
        let selected = Set(configuration.selectedCardIds)

        // Filtering the cache down to the selection, rather than mapping the
        // selection onto the cache, is the whole ordering rule: the cache
        // arrives sorted by priority, so the producer decides which of a
        // reader's picks lead. An empty selection selects everything, which is
        // how a grid nobody has configured follows the dashboard's top cards.
        let candidates = selected.isEmpty ? cached : cached.filter { selected.contains($0.id) }
        let cards = Array(
            candidates.filter { filter.includes($0.status) }.prefix(capacity)
        )

        let reason: CardFallbackView.Reason?
        if !cards.isEmpty {
            reason = nil
        } else if candidates.isEmpty {
            // Either nothing is cached, or every picked card has since been
            // deleted. Both read as "no data" from here.
            reason = .noCachedData
        } else {
            reason = .filtered(filter.fallbackLabel)
        }

        return CardGridEntry(
            date: Date(),
            cards: cards,
            reason: reason,
            compactTapTarget: configuration.compactTapTarget,
            density: configuration.density,
            statusFilter: configuration.statusFilter
        )
    }
}

struct CardGridWidget: Widget {
    let kind: String = ZeroZeroWidgetConstants.WidgetKinds.cardGrid

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectGridCardsIntent.self,
            provider: CardGridTimelineProvider()
        ) { entry in
            CardGridWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("00Widget Grid")
        .description("Show several 00Widget cards at once, highest priority first.")
        .supportedFamilies(FullPageWidgetFamily.adding(to: [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]))
        .pushHandler(ZeroZeroWidgetPushHandler.self)
    }
}

struct CardGridWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: CardGridEntry

    var body: some View {
        content
            .widgetUpdateStamp(entry.updateMark)
            .widgetURL(family == .systemSmall ? compactTapURL : nil)
    }

    @ViewBuilder
    private var content: some View {
        if let reason = entry.reason {
            CardFallbackView(reason: reason)
        } else {
            grid
        }
    }

    private var compactTapURL: URL? {
        guard let index = entry.compactTapTarget.cardIndex else { return nil }
        return entry.cards[safe: index]?.deepLink
    }

    private var cellStyle: CardGridCell.Style {
        switch entry.density {
        case .compact:
            return .compact
        case .detailed:
            return family == .systemSmall ? .standard : .roomy
        case .automatic:
            break
        }

        switch family {
        case .systemSmall: return .compact
        case .systemMedium: return .standard
        default:
            // A double-width grid fits eight cells into the height that gives
            // `systemLarge` four, so each one lands nearer a small widget than
            // a large one and `.roomy` would overdraw it.
            return entry.cards.count > 4 ? .standard : .roomy
        }
    }

    /// Lays out one cell per card instead of a fixed 2x2. Fewer than four cards
    /// is the common case — three followed cards should read as three tiles, not
    /// as three tiles and a dashed hole — and a lone card gets the whole widget.
    @ViewBuilder
    private var grid: some View {
        let spacing: CGFloat = family == .systemSmall ? 6 : 8
        let linkable = family != .systemSmall
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            switch entry.cards.count {
            case 1:
                GridRow { cell(at: 0, linkable: linkable) }
            case 2:
                GridRow {
                    cell(at: 0, linkable: linkable)
                    cell(at: 1, linkable: linkable)
                }
            case 3:
                GridRow {
                    cell(at: 0, linkable: linkable)
                    cell(at: 1, linkable: linkable)
                }
                GridRow {
                    cell(at: 2, linkable: linkable).gridCellColumns(2)
                }
            case 4:
                GridRow {
                    cell(at: 0, linkable: linkable)
                    cell(at: 1, linkable: linkable)
                }
                GridRow {
                    cell(at: 2, linkable: linkable)
                    cell(at: 3, linkable: linkable)
                }
            default:
                // Only the extra-large families reach here: every other one is
                // capped at four by `SelectGridCardsIntent.capacity(for:)`.
                // Column count follows which way the canvas grew — iPad's is
                // twice as wide at the same height, so four across; iOS 27's
                // full page is `systemLarge`'s width and taller, so two across
                // and more rows. Four columns there would be a strip of slivers.
                let columns = FullPageWidgetFamily.contains(family) ? 2 : 4
                ForEach(Array(stride(from: 0, to: entry.cards.count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(Array(start..<min(start + columns, entry.cards.count)), id: \.self) { index in
                            cell(at: index, linkable: linkable)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(at index: Int, linkable: Bool) -> some View {
        if let card = entry.cards[safe: index] {
            let view = CardGridCell(card: card, style: cellStyle)
            if linkable, let url = card.deepLink {
                Link(destination: url) { view }
            } else {
                view
            }
        }
    }
}

struct CardGridCell: View {
    enum Style {
        case compact, standard, roomy

        /// A compact cell is barely taller than its own headline number, so
        /// there is no band to fill. The other two have roughly a third of
        /// their height going spare between the title and the value.
        var showsInlineVisual: Bool { self != .compact }

        var plotLineWidth: CGFloat { self == .roomy ? 1.8 : 1.4 }
        var barHeight: CGFloat { self == .roomy ? 10 : 8 }
        var historyLimit: Int { self == .roomy ? 10 : 7 }

        /// A cell is the narrowest place a chart is drawn, and `.standard`
        /// spans the widest range of them — two columns of a small widget in
        /// detailed density are barely 65pt across, while four columns of an
        /// iPad's extra-large canvas are nearer 170. The cap follows the
        /// narrowest, because the same style has to hold up in both.
        var plotPointLimit: Int { self == .roomy ? 24 : 16 }
    }

    /// The visual a cell can draw in the space between its title and its
    /// value, if the card carries what one needs.
    enum InlineVisual {
        case plot(DashboardChart)
        case history([DashboardItem])
        case breakdown([DashboardItem])
        case progress(Double)

        /// Only the plot wants the whole band. The others are a few points
        /// tall and read better sitting just above the value, with the slack
        /// above them.
        var fillsBand: Bool {
            if case .plot = self { return true }
            return false
        }
    }

    let card: DashboardCard
    let style: Style
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            if renderingMode == .fullColor {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background.secondary)
            }
            content
                .padding(style == .compact ? 6 : 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .compact: compactCell(card)
        case .standard: standardCell(card)
        case .roomy: roomyCell(card)
        }
    }

    /// What the cell can draw in its spare band.
    ///
    /// A grid cell ignores `template` everywhere else — it is a compressed
    /// view, and every card reduces to icon, title, value, subtitle. But each
    /// template already has a glanceable visual built for exactly this kind of
    /// constrained space, and the band was sitting empty. So the cell draws
    /// whichever one the card can fill, and nothing when it carries none.
    ///
    /// The plot outranks progress, matching the Live Activity: a producer
    /// sending both has a number that moves, and the plot says which way while
    /// a bar only says how far.
    private var inlineVisual: InlineVisual? {
        guard style.showsInlineVisual else { return nil }
        if let chart = card.chart, chart.isRenderable { return .plot(chart) }
        if let items = card.items, !items.isEmpty {
            switch card.template {
            case .history: return .history(items)
            case .breakdown: return .breakdown(items)
            default: break
            }
        }
        if let progress = card.progressValue { return .progress(progress) }
        return nil
    }

    @ViewBuilder
    private func inlineVisualBody(_ visual: InlineVisual) -> some View {
        switch visual {
        case .plot(let chart):
            SparklineView(
                chart: chart,
                tint: card.status.tint,
                lineWidth: style.plotLineWidth,
                maxPoints: style.plotPointLimit
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .history(let items):
            StatusStripView(items: items, limit: style.historyLimit, height: style.barHeight)
        case .breakdown(let items):
            CompositionBarView(items: items, tint: card.status.tint, height: style.barHeight)
        case .progress(let value):
            ProgressRow(progress: value, label: nil)
        }
    }

    /// The band itself. A plot takes the slack; anything else lets a `Spacer`
    /// take it first and sits just above the value. With no visual at all this
    /// is the plain `Spacer` the cell has always had.
    @ViewBuilder
    private var band: some View {
        if let visual = inlineVisual {
            if visual.fillsBand {
                inlineVisualBody(visual)
            } else {
                Spacer(minLength: 0)
                inlineVisualBody(visual)
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    private func compactCell(_ card: DashboardCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Image(systemName: card.icon ?? "circle.fill")
                    .font(.callout)
                    .foregroundStyle(card.status.tint)
                Spacer(minLength: 0)
                if let statusIcon = card.statusIcon {
                    Image(systemName: statusIcon)
                        .font(.caption2)
                        .foregroundStyle(card.status.tint)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(card.value ?? "—")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(card.status.tint)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let unit = card.unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func standardCell(_ card: DashboardCard) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: card.icon ?? "circle.fill")
                    .font(.caption)
                    .foregroundStyle(card.status.tint)
                Text(card.title)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let statusIcon = card.statusIcon {
                    Image(systemName: statusIcon)
                        .font(.caption2)
                        .foregroundStyle(card.status.tint)
                }
            }
            band
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(card.value ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(card.status.tint)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let unit = card.unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func roomyCell(_ card: DashboardCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: card.icon ?? "circle.fill")
                    .font(.footnote)
                    .foregroundStyle(card.status.tint)
                Text(card.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let statusIcon = card.statusIcon {
                    Image(systemName: statusIcon)
                        .font(.caption)
                        .foregroundStyle(card.status.tint)
                }
            }
            band
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(card.value ?? "—")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(card.status.tint)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let unit = card.unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
