import WidgetKit
import SwiftUI
import AppIntents
import Foundation
import os

public struct SelectFourCardsIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Select metrics"
    public static var description = IntentDescription("Choose up to four cards to display as a 2x2 grid.")

    @Parameter(title: "Top left")
    public var card1: CardEntity?

    @Parameter(title: "Top right")
    public var card2: CardEntity?

    @Parameter(title: "Bottom left")
    public var card3: CardEntity?

    @Parameter(title: "Bottom right")
    public var card4: CardEntity?

    public init() {
        let cards = CardCache.load().cards
        func slot(_ index: Int) -> CardEntity? {
            guard cards.indices.contains(index) else { return nil }
            return CardEntity(id: cards[index].id, title: cards[index].title)
        }
        self.card1 = slot(0)
        self.card2 = slot(1)
        self.card3 = slot(2)
        self.card4 = slot(3)
    }
}

public struct MetricsGridEntry: TimelineEntry {
    public let date: Date
    public let slots: [DashboardCard?]
    public let allUnconfigured: Bool

    public init(date: Date, slots: [DashboardCard?], allUnconfigured: Bool) {
        self.date = date
        self.slots = slots
        self.allUnconfigured = allUnconfigured
    }
}

public struct MetricsGridTimelineProvider: AppIntentTimelineProvider {
    public typealias Intent = SelectFourCardsIntent
    public typealias Entry = MetricsGridEntry

    private static let log = Logger(subsystem: "com.example.zerozerowidget", category: "Timeline")

    public init() {}

    public func placeholder(in context: Context) -> MetricsGridEntry {
        let cards = SampleDataFactory.makeCards()
        let slots: [DashboardCard?] = (0..<4).map { i in i < cards.count ? cards[i] : nil }
        return MetricsGridEntry(date: Date(), slots: slots, allUnconfigured: false)
    }

    public func snapshot(for configuration: SelectFourCardsIntent, in context: Context) async -> MetricsGridEntry {
        await refreshCacheIfPossible(reason: "snapshot")
        return entry(for: configuration)
    }

    public func timeline(for configuration: SelectFourCardsIntent, in context: Context) async -> Timeline<MetricsGridEntry> {
        await refreshCacheIfPossible(reason: "timeline")
        let entry = entry(for: configuration)
        let refresh = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    private func refreshCacheIfPossible(reason: String) async {
        guard let config = APIClientConfig.fromSettings() else {
            Self.log.info("skipping grid refresh for \(reason, privacy: .public): API config unavailable")
            return
        }
        do {
            let cards = try await APIClient(config: config).fetchCards()
            try CardCache.save(cards)
            Self.log.info("refreshed \(cards.count, privacy: .public) cards for \(reason, privacy: .public)")
        } catch {
            Self.log.error("grid refresh failed for \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func entry(for configuration: SelectFourCardsIntent) -> MetricsGridEntry {
        let rawIds = [configuration.card1?.id, configuration.card2?.id, configuration.card3?.id, configuration.card4?.id]
        let ids: [String?] = rawIds.map { id in
            guard let id, id != CardEntityQuery.noneId else { return nil }
            return id
        }
        let allUnconfigured = ids.allSatisfy { $0 == nil }
        let cached = CardCache.load().cards
        let slots: [DashboardCard?] = ids.map { id in
            guard let id else { return nil }
            return cached.first(where: { $0.id == id })
        }
        return MetricsGridEntry(date: Date(), slots: slots, allUnconfigured: allUnconfigured)
    }
}

struct MetricsGridWidget: Widget {
    let kind: String = ZeroZeroWidgetConstants.WidgetKinds.metricsGrid

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectFourCardsIntent.self,
            provider: MetricsGridTimelineProvider()
        ) { entry in
            MetricsGridWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Metrics grid")
        .description("Show up to four metrics in a 2x2 grid.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .pushHandler(ZeroZeroWidgetPushHandler.self)
    }
}

struct MetricsGridWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: MetricsGridEntry

    var body: some View {
        if entry.allUnconfigured {
            CardFallbackView(reason: .noCardSelected)
        } else {
            grid
        }
    }

    private var cellStyle: MetricsGridCell.Style {
        switch family {
        case .systemSmall: return .compact
        case .systemMedium: return .standard
        default: return .roomy
        }
    }

    private var grid: some View {
        let spacing: CGFloat = family == .systemSmall ? 6 : 8
        let linkable = family != .systemSmall
        return Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
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

    @ViewBuilder
    private func cell(at index: Int, linkable: Bool) -> some View {
        let card = entry.slots[safe: index] ?? nil
        let view = MetricsGridCell(card: card, style: cellStyle)
        if linkable, let url = card?.deepLink {
            Link(destination: url) { view }
        } else {
            view
        }
    }
}

struct MetricsGridCell: View {
    enum Style { case compact, standard, roomy }

    let card: DashboardCard?
    let style: Style

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.secondary)
            content
                .padding(style == .compact ? 6 : 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let card {
            switch style {
            case .compact: compactCell(card)
            case .standard: standardCell(card)
            case .roomy: roomyCell(card)
            }
        } else {
            emptyCell
        }
    }

    private var emptyCell: some View {
        Image(systemName: "square.dashed")
            .font(.title3)
            .foregroundStyle(.tertiary)
    }

    private func compactCell(_ card: DashboardCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: card.icon ?? "circle.fill")
                .font(.callout)
                .foregroundStyle(card.status.tint)
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
