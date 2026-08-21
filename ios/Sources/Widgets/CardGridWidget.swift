import WidgetKit
import SwiftUI
import AppIntents
import Foundation
import os

public enum CardGridTapTarget: String, AppEnum {
    case app
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Tap action")
    }

    public static var caseDisplayRepresentations: [CardGridTapTarget: DisplayRepresentation] = [
        .app: DisplayRepresentation(title: "Open the app"),
        .topLeft: DisplayRepresentation(title: "Open top-left card"),
        .topRight: DisplayRepresentation(title: "Open top-right card"),
        .bottomLeft: DisplayRepresentation(title: "Open bottom-left card"),
        .bottomRight: DisplayRepresentation(title: "Open bottom-right card")
    ]
}

public struct SelectFourCardsIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Select cards"
    public static var description = IntentDescription("Choose up to four cards to display as a 2x2 grid.")

    @Parameter(title: "Top left")
    public var card1: CardEntity?

    @Parameter(title: "Top right")
    public var card2: CardEntity?

    @Parameter(title: "Bottom left")
    public var card3: CardEntity?

    @Parameter(title: "Bottom right")
    public var card4: CardEntity?

    @Parameter(title: "On compact tap", default: .app)
    public var compactTapTarget: CardGridTapTarget

    @Parameter(title: "Display density", default: .automatic)
    public var density: WidgetCardDensity

    @Parameter(title: "Show statuses", default: .all)
    public var statusFilter: WidgetStatusFilter

    public init() {
        let cards = CardCache.cardsForWidgets()
        func slot(_ index: Int) -> CardEntity? {
            guard cards.indices.contains(index) else { return nil }
            return CardEntity(id: cards[index].id, title: cards[index].title)
        }
        self.card1 = slot(0)
        self.card2 = slot(1)
        self.card3 = slot(2)
        self.card4 = slot(3)
        self.compactTapTarget = .app
        self.density = .automatic
        self.statusFilter = .all
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
    public typealias Intent = SelectFourCardsIntent
    public typealias Entry = CardGridEntry

    private static let log = Logger(subsystem: "com.example.zerozerowidget", category: "Timeline")

    public init() {}

    public func placeholder(in context: Context) -> CardGridEntry {
        return CardGridEntry(
            date: Date(),
            cards: Array(SampleDataFactory.makeCards().prefix(4)),
            compactTapTarget: .app,
            density: .automatic,
            statusFilter: .all
        )
    }

    public func snapshot(for configuration: SelectFourCardsIntent, in context: Context) async -> CardGridEntry {
        await refreshCacheIfPossible(reason: "snapshot")
        return entry(for: configuration)
    }

    public func timeline(for configuration: SelectFourCardsIntent, in context: Context) async -> Timeline<CardGridEntry> {
        let refreshed = await refreshCacheIfPossible(reason: "timeline")
        // Keyed by what this placement shows, so two grids do not overwrite
        // each other's history.
        let slots = [configuration.card1, configuration.card2, configuration.card3, configuration.card4]
        let widgetKey = "grid.\(slots.compactMap { $0?.id }.joined(separator: "+"))"
        let decision = WidgetRefreshPolicy.decide(for: widgetKey)
        let mark = WidgetUpdateMark(
            date: Date(),
            source: WidgetUpdateSource.classify(
                wokenEarly: decision.wokenEarly,
                refreshSucceeded: refreshed,
                appReloadAt: SharedSettings.lastAppWidgetReloadAt
            )
        )
        return Timeline(entries: [entry(for: configuration).marked(mark)], policy: .after(decision.next))
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

    private func entry(for configuration: SelectFourCardsIntent) -> CardGridEntry {
        let filter = configuration.statusFilter
        let cached = CardCache.cardsForWidgets()
        let selections = [configuration.card1, configuration.card2, configuration.card3, configuration.card4]
        let isConfigured = selections.contains { $0 != nil }
        let ids = selections.compactMap { $0?.id }.filter { $0 != CardEntityQuery.noneId }

        // Nothing configured means a placement nobody has opened the sheet for.
        // Fill it with the first cards there are — as many as exist, each one
        // once — rather than showing four "Pick a card" cells.
        let candidates = isConfigured ? ids.compactMap { id in cached.first(where: { $0.id == id }) } : cached
        let cards = Array(candidates.filter { filter.includes($0.status) }.prefix(4))

        let reason: CardFallbackView.Reason?
        if !cards.isEmpty {
            reason = nil
        } else if isConfigured && ids.isEmpty {
            reason = .noCardSelected            // every slot deliberately set to None
        } else if candidates.isEmpty {
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
            intent: SelectFourCardsIntent.self,
            provider: CardGridTimelineProvider()
        ) { entry in
            CardGridWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("00Widget Grid")
        .description("Show up to four 00Widget cards in a 2x2 grid.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
        let index: Int
        switch entry.compactTapTarget {
        case .app: return nil
        case .topLeft: index = 0
        case .topRight: index = 1
        case .bottomLeft: index = 2
        case .bottomRight: index = 3
        }
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
        default: return .roomy
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
            default:
                GridRow {
                    cell(at: 0, linkable: linkable)
                    cell(at: 1, linkable: linkable)
                }
                GridRow {
                    cell(at: 2, linkable: linkable)
                    cell(at: 3, linkable: linkable)
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
    enum Style { case compact, standard, roomy }

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
            Spacer(minLength: 0)
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
            Spacer(minLength: 0)
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
