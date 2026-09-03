import SwiftUI
import AppIntents
#if canImport(WidgetKit)
import WidgetKit
#endif

extension DashboardCard {
    /// Whether to draw the "SAMPLE" badge. Demo data stays labelled in normal
    /// use; Settings → Developer can suppress the labelling so the marketing
    /// screenshots show the product rather than the disclaimer. Lives here
    /// rather than on the model so the app and the widget extension, which both
    /// render through this file, cannot disagree.
    var showsSampleBadge: Bool {
        isSample && !SharedSettings.hideSampleIndicators
    }
}

public enum CardRenderContext {
    case app
    case widgetSmall
    case widgetMedium
    case widgetLarge
    /// `systemExtraLarge` on iPad: roughly twice the width of `systemLarge`
    /// at the same height. The room it adds is *horizontal*.
    case widgetExtraLarge
    /// iOS 27's `systemExtraLargePortrait`: reportedly a 4x6 canvas, so the
    /// same width as `systemLarge` and half again its height. The room it adds
    /// is *vertical* — the opposite axis to `widgetExtraLarge`, which is why
    /// the two are separate cases rather than one "extra large". Sharing a
    /// layout between them would column-split a canvas that has no width to
    /// spare.
    case widgetExtraLargePortrait
    case accessoryRectangular
    case accessoryCircular
    case accessoryInline
}

public enum CardRenderDensity: String, Hashable, Sendable {
    case automatic
    case compact
    case detailed
}

public struct CardView: View {
    public let card: DashboardCard
    public let context: CardRenderContext
    public let density: CardRenderDensity
    private let showsAppChart: Bool
    private let appActionIsBusy: ((ActionDefinition) -> Bool)?
    private let appActionHandler: ((ActionDefinition) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// A `.caption` list row and the gap under it, at the reader's text size.
    /// It is both the unit a filling list measures its row count in and the
    /// unit its type ladder steps against, so a larger text size buys fewer,
    /// taller rows rather than a card that overflows.
    @ScaledMetric(relativeTo: .caption) private var listRowUnit: CGFloat = 19
    /// The same measurement for a `breakdown`'s legend, whose rows are a rung
    /// smaller than a list's.
    @ScaledMetric(relativeTo: .caption2) private var legendRowUnit: CGFloat = 17
    /// A `summary` headline on a canvas whose whole job is to carry it. There
    /// is no text style above `.largeTitle`, and `.largeTitle` centred in a
    /// large widget reads as a small number adrift rather than as the point of
    /// the card, so this is a point size — scaled with the reader's text size
    /// like a style, and shrunk by `minimumScaleFactor` when the value is long.
    @ScaledMetric(relativeTo: .largeTitle) private var summaryValueSize: CGFloat = 56
    /// The same on the medium canvas, which has a third of the height.
    @ScaledMetric(relativeTo: .largeTitle) private var summaryValueSizeMedium: CGFloat = 40
    /// The line a filling stack spends to say what it left out.
    @ScaledMetric(relativeTo: .caption2) private var truncationLineUnit: CGFloat = 14
    /// One line of a briefing section's prose, and the label line above it,
    /// at the reader's text size.
    @ScaledMetric(relativeTo: .caption) private var briefingLineUnit: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var briefingLabelUnit: CGFloat = 15
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    #if canImport(WidgetKit)
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    #endif

    public init(
        card: DashboardCard,
        context: CardRenderContext = .app,
        density: CardRenderDensity = .automatic,
        showsAppChart: Bool = true,
        appActionIsBusy: ((ActionDefinition) -> Bool)? = nil,
        appActionHandler: ((ActionDefinition) -> Void)? = nil
    ) {
        self.card = card
        self.context = context
        self.density = density
        self.showsAppChart = showsAppChart
        self.appActionIsBusy = appActionIsBusy
        self.appActionHandler = appActionHandler
    }

    public var body: some View {
        Group {
            switch context {
            case .accessoryInline:
                inlineView
            case .accessoryCircular:
                circularView
            case .accessoryRectangular:
                rectangularView
            case .widgetSmall:
                smallView
            case .widgetMedium:
                mediumView
            case .widgetLarge:
                largeView
            case .widgetExtraLarge:
                extraLargeView
            case .widgetExtraLargePortrait:
                extraLargePortraitView
            case .app:
                appView
            }
        }
        .modifier(CardAccessibilityModifier(card: card, combinesChildren: combinesAccessibilityChildren))
    }

    private var combinesAccessibilityChildren: Bool {
        switch context {
        case .app:
            return density == .compact
        case .widgetSmall, .widgetMedium, .widgetLarge, .widgetExtraLarge, .widgetExtraLargePortrait:
            return card.actions?.isEmpty ?? true
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = card.icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(card.status.tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                producerLine(font: .caption2)
            }
            if card.isFromGuestLink { guestBadge }
            if card.showsSampleBadge { sampleBadge }
            Spacer(minLength: 0)
            if let statusIcon = card.statusIcon {
                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundStyle(card.status.tint)
            }
            // Healthy and normally active cards need no extra chrome in the
            // constrained widget canvas. Keep only states that ask for
            // attention; the combined accessibility summary still says the
            // status aloud.
            if card.needsUserAttention {
                AttentionBadge()
            } else if card.status.needsAttention {
                StatusBadge(status: card.status, compact: true)
            }
        }
    }

    @ViewBuilder
    private func producerLine(font: Font) -> some View {
        if showsProducer, let producer = card.producer {
            HStack(spacing: 3) {
                if let icon = producer.icon {
                    Image(systemName: icon)
                        .accessibilityHidden(true)
                }
                Text(producer.label)
                    .lineLimit(1)
            }
            .font(font)
            .foregroundStyle(.secondary)
        }
    }

    private var showsProducer: Bool {
        guard density != .compact, card.producer != nil else { return false }
        switch context {
        case .app, .widgetLarge, .widgetExtraLarge, .widgetExtraLargePortrait:
            return true
        case .widgetSmall, .widgetMedium, .accessoryRectangular,
             .accessoryCircular, .accessoryInline:
            return false
        }
    }

    /// A producer-supplied deadline is useful enough to spend scarce widget
    /// space on because the device keeps it accurate between reloads. The
    /// card's generic updated-at age is deliberately absent here: a timer that
    /// changes every second is visual noise, not card content. Freshness remains
    /// available in the app detail and in the accessibility stale warning.
    @ViewBuilder
    private var deadlineLine: some View {
        if let deadline = card.deadline {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                Text(deadline, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// Marks a card followed through someone else's shared link, so a card on
    /// the Home Screen is never mistaken for one of your own. Unlike the sample
    /// badge this is not suppressible: it states whose data this is, which is
    /// not a disclaimer that can be turned off for a screenshot.
    private var guestBadge: some View {
        Image(systemName: "link")
            .font(.system(size: 9, weight: .bold))
            .padding(4)
            .background(Circle().fill(Color.secondary.opacity(0.18)))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Shared with you")
            .fixedSize()
    }

    /// Marks cards generated by `SampleDataFactory` so demo data is never
    /// mistaken for something an agent published — including on the Home
    /// Screen, where the widget is all the user sees.
    private var sampleBadge: some View {
        Text("SAMPLE")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.12)))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
    }

    private func bigValue(font: Font = .title, unitFont: Font = .caption) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(card.value ?? "—")
                    .font(font.weight(.semibold))
                    .fontDesign(.rounded)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let unit = card.unit {
                    Text(unit)
                        .font(unitFont)
                        .foregroundStyle(.secondary)
                }
            }
            comparisonLine(font: .caption2)
        }
    }

    @ViewBuilder
    private func comparisonLine(font: Font) -> some View {
        if let comparison = card.comparison {
            HStack(spacing: 4) {
                Image(systemName: comparison.signal.symbolName)
                    .accessibilityHidden(true)
                Text(comparison.value)
                    .fontWeight(.semibold)
                Text(comparison.label)
                    .foregroundStyle(.secondary)
            }
            .font(font)
            .foregroundStyle(comparison.signal.tint)
            .lineLimit(1)
        }
    }

    /// The headline number on a card that exists to show one.
    ///
    /// `summary` is the template the integration guide tells producers to
    /// default to, and its number was `.title` on every canvas — the same size
    /// in a 170-point small widget and in a large one with four times the
    /// area, where it sat above four fifths of a blank card. A chart, history
    /// or breakdown headline deliberately does not grow with it: there the
    /// number introduces something drawn underneath, and the height belongs to
    /// that.
    @ViewBuilder
    private var summaryValue: some View {
        switch context {
        case .widgetLarge, .widgetExtraLargePortrait:
            bigValue(font: .system(size: summaryValueSize, design: .rounded), unitFont: .title2)
        case .widgetExtraLarge:
            // Half the width, and action buttons in the column beside it.
            bigValue(font: .largeTitle, unitFont: .title3)
        case .widgetMedium:
            bigValue(font: .system(size: summaryValueSizeMedium, design: .rounded), unitFont: .subheadline)
        default:
            bigValue()
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !rowsFillHeight {
                Spacer(minLength: 0)
            }
            switch card.template {
            case .progress:
                if let p = card.progressValue {
                    if card.progressValueIsLabel { bigValue() }
                    ProgressRow(progress: p, label: card.subtitle)
                } else {
                    bigValue()
                }
            case .action:
                actionSummary
                actionButtons(max: 1)
            case .list:
                listRows(max: density == .compact ? 3 : 4, fills: true)
            case .chart:
                chartHeadline
                sparkline(height: 30, lineWidth: 1.8, maxPoints: 32)
            case .history:
                chartHeadline
                statusStrip(limit: 10, height: 12)
            case .breakdown:
                chartHeadline
                compositionBar(height: 12)
            case .briefing:
                briefingLead(subtitleLines: 2)
            case .summary:
                bigValue()
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if card.template != .action {
                actionButtons(max: density == .compact ? 0 : 1)
            }
            if card.deadline != nil { deadlineLine }
        }
        .padding(8)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch card.template {
            case .list:
                listRows(max: density == .compact ? 4 : 6, fills: true)
            case .action:
                actionSummary
                actionButtons(max: density == .compact ? 1 : 2)
            case .progress:
                VStack(alignment: .leading, spacing: 6) {
                    summaryValue
                    if let p = card.progressValue {
                        ProgressRow(progress: p, label: card.subtitle)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            case .chart:
                chartHeadline
                sparkline(height: density == .compact ? 32 : 46)
                if density != .compact {
                    chartSupplement(legendLimit: 2, labelLimit: 0)
                }
            case .history:
                chartHeadline
                statusStrip(limit: density == .compact ? 12 : 14, height: 14)
            case .breakdown:
                chartHeadline
                compositionBar(height: 14)
                breakdownLegend(max: density == .compact ? 2 : 4, fills: true)
            case .briefing:
                briefingLead(subtitleLines: density == .compact ? 1 : 2)
                briefingSections(max: density == .compact ? 0 : 1, lineLimit: 2)
            case .summary:
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        summaryValue
                        if density != .compact, let subtitle = card.subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .frame(maxHeight: .infinity, alignment: .leading)
            }
            if card.template != .action {
                actionButtons(max: density == .compact ? 1 : 2)
            }
            if !bodyFillsHeight {
                Spacer(minLength: 0)
            }
            if density != .compact, card.deadline != nil {
                deadlineLine
            }
        }
        .padding(10)
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch card.template {
            case .list:
                listRows(max: density == .compact ? 6 : 10, fills: true)
            case .action:
                actionSummary
                actionButtons(max: density == .compact ? 2 : 4)
            case .chart:
                chartHeadline
                sparkline(minHeight: density == .compact ? 60 : 90, lineWidth: 2.5)
                chartSupplement(
                    legendLimit: density == .compact ? 2 : 4,
                    labelLimit: density == .compact ? 0 : 5
                )
            case .history:
                chartHeadline
                statusStrip(limit: 20, height: 16)
                listRows(max: density == .compact ? 3 : 6, fills: true)
            case .breakdown:
                chartHeadline
                compositionBar(height: 16)
                breakdownLegend(max: density == .compact ? 4 : 8, fills: true)
            case .briefing:
                briefingLead(subtitleLines: 2)
                briefingSections(max: density == .compact ? 2 : 4, fills: true)
            case .summary, .progress:
                VStack(alignment: .leading, spacing: 8) {
                    summaryValue
                    if let subtitle = card.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let p = card.progressValue {
                        ProgressRow(progress: p, label: nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            if card.template != .action {
                actionButtons(max: density == .compact ? 2 : 4)
            }
            // The plot already claims the slack when it is drawn; a Spacer as
            // well would split the leftover height between them and leave the
            // chart short again.
            if !bodyFillsHeight {
                Spacer(minLength: 0)
            }
            if density != .compact, card.deadline != nil {
                deadlineLine
            }
        }
        .padding(12)
    }

    /// Whether the body hands itself the canvas's spare vertical space instead
    /// of leaving it to a trailing `Spacer`. Two things that both grow split
    /// the slack and neither one fills, so a filling body and the Spacer are
    /// exclusive at every call site.
    private var bodyFillsHeight: Bool {
        largePlotFillsHeight || rowsFillHeight || summaryFillsHeight
    }

    /// Whether stacked rows — a `list`'s, or a `breakdown`'s legend under its
    /// bar — spread over the canvas rather than sitting under the header at a
    /// fixed size and a fixed count.
    ///
    /// Every single-column widget canvas qualifies. The double-width one does
    /// not: it answers extra room with a second column, and two columns
    /// measuring their own height independently would disagree about how many
    /// rows fit and leave a hole in the middle of the sequence.
    private var rowsFillHeight: Bool {
        switch (card.template, context) {
        case (.list, .widgetSmall), (.list, .widgetMedium),
             (.list, .widgetLarge), (.list, .widgetExtraLargePortrait):
            return !(card.items?.isEmpty ?? true)
        // A small widget draws the bar and no legend, so it has no rows here.
        case (.breakdown, .widgetMedium), (.breakdown, .widgetLarge),
             (.breakdown, .widgetExtraLargePortrait):
            return !(card.items?.isEmpty ?? true)
        // Only the tall canvases draw history's rows under the strip.
        case (.history, .widgetLarge), (.history, .widgetExtraLargePortrait):
            return !(card.items?.isEmpty ?? true)
        case (.briefing, .widgetLarge), (.briefing, .widgetExtraLargePortrait):
            return !(card.briefing?.sections.isEmpty ?? true)
        default:
            return false
        }
    }

    /// Whether a card whose whole content is a headline number centres that
    /// number in the room instead of hanging it under the header with the rest
    /// of the canvas blank beneath it.
    private var summaryFillsHeight: Bool {
        switch (card.template, context) {
        case (.summary, .widgetMedium), (.progress, .widgetMedium),
             (.summary, .widgetLarge), (.progress, .widgetLarge),
             (.summary, .widgetExtraLargePortrait), (.progress, .widgetExtraLargePortrait):
            return true
        default:
            return false
        }
    }

    /// Whether `largeView` hands its spare vertical space to the plot instead
    /// of to a trailing `Spacer`. Only true when a plot is actually drawn — a
    /// `chart` card whose series is too short to render has nothing to grow,
    /// and would otherwise centre its text in the widget. The small and medium
    /// canvases are excluded because their plots are a fixed height there and
    /// so have nothing to grow into.
    private var largePlotFillsHeight: Bool {
        switch context {
        case .widgetLarge, .widgetExtraLarge, .widgetExtraLargePortrait:
            return card.template == .chart && (card.chart?.isRenderable ?? false)
        default:
            return false
        }
    }

    /// The double-width canvas: `systemExtraLarge` on iPad, and iOS 27's
    /// `systemExtraLargePortrait`. Both are roughly twice the width of
    /// `systemLarge` at the *same* height, so the room they add is horizontal.
    /// This used to fall through to `largeView`, which spends new space
    /// vertically and therefore left a column of content beside a wide empty
    /// band. Each template now puts the width to work as a second column
    /// instead of asking for taller content it has no height for.
    private var extraLargeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            extraLargeBody
            // Same bargain as `largeView`: a plot that grows into the slack
            // must not also compete with a Spacer for it.
            if !bodyFillsHeight {
                Spacer(minLength: 0)
            }
            if density != .compact, card.deadline != nil {
                deadlineLine
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var extraLargeBody: some View {
        let rowsPerColumn = density == .compact ? 5 : 7
        switch card.template {
        case .list:
            HStack(alignment: .top, spacing: 14) {
                listRows(max: rowsPerColumn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A short list keeps one column and the full width per row,
                // rather than a half-empty second column beside it.
                if (card.items?.count ?? 0) > rowsPerColumn {
                    listRows(max: rowsPerColumn, dropping: rowsPerColumn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            actionButtons(max: density == .compact ? 2 : 4)
        case .action:
            HStack(alignment: .top, spacing: 14) {
                actionSummary
                    .frame(maxWidth: .infinity, alignment: .leading)
                if drawsActionButtons {
                    actionButtons(max: density == .compact ? 4 : 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .chart:
            HStack(alignment: .top, spacing: 14) {
                // The headline is a number and a label; the plot is the reason
                // for the canvas, so it takes the remaining width rather than
                // an even half of it.
                VStack(alignment: .leading, spacing: 8) {
                    chartHeadline
                    actionButtons(max: density == .compact ? 2 : 4)
                }
                .frame(maxWidth: 200, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    sparkline(minHeight: density == .compact ? 70 : 110, lineWidth: 2.5)
                    chartSupplement(
                        legendLimit: density == .compact ? 2 : 4,
                        labelLimit: density == .compact ? 0 : 6
                    )
                }
                .frame(maxWidth: .infinity)
            }
        case .history:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    chartHeadline
                    statusStrip(limit: 30, height: 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                listRows(max: rowsPerColumn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionButtons(max: density == .compact ? 2 : 4)
        case .breakdown:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    chartHeadline
                    compositionBar(height: 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                breakdownLegend(max: density == .compact ? 5 : 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionButtons(max: density == .compact ? 2 : 4)
        case .briefing:
            HStack(alignment: .top, spacing: 14) {
                briefingLead(subtitleLines: 3)
                    .frame(maxWidth: 220, alignment: .leading)
                briefingSections(max: density == .compact ? 3 : 6, lineLimit: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionButtons(max: density == .compact ? 2 : 4)
        case .summary, .progress:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    summaryValue
                    if let subtitle = card.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let p = card.progressValue {
                        ProgressRow(progress: p, label: nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if drawsActionButtons {
                    actionButtons(max: density == .compact ? 4 : 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The tall full-page canvas: iOS 27's `systemExtraLargePortrait`, the
    /// same width as `systemLarge` and about half again its height. Where
    /// `extraLargeView` answers extra width with a second column, this answers
    /// extra height by giving each template a larger vertical budget — more
    /// rows, a taller plot, more buttons — in the one column the width allows.
    private var extraLargePortraitView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch card.template {
            case .list:
                listRows(max: density == .compact ? 8 : 12, fills: true)
            case .action:
                actionSummary
                actionButtons(max: density == .compact ? 5 : 8)
            case .chart:
                chartHeadline
                sparkline(minHeight: density == .compact ? 100 : 150, lineWidth: 2.5)
                chartSupplement(
                    legendLimit: density == .compact ? 2 : 4,
                    labelLimit: density == .compact ? 0 : 6
                )
            case .history:
                chartHeadline
                statusStrip(limit: 30, height: 18)
                listRows(max: density == .compact ? 5 : 9, fills: true)
            case .breakdown:
                chartHeadline
                compositionBar(height: 18)
                breakdownLegend(max: density == .compact ? 6 : 10, fills: true)
            case .briefing:
                briefingLead(subtitleLines: 3)
                briefingSections(max: density == .compact ? 4 : 8, fills: true)
            case .summary, .progress:
                VStack(alignment: .leading, spacing: 10) {
                    summaryValue
                    if let subtitle = card.subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    if let p = card.progressValue {
                        ProgressRow(progress: p, label: nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            if card.template != .action {
                actionButtons(max: density == .compact ? 3 : 6)
            }
            if !bodyFillsHeight {
                Spacer(minLength: 0)
            }
            if density != .compact, card.deadline != nil {
                deadlineLine
            }
        }
        .padding(14)
    }

    /// Whether `actionButtons` would draw anything, mirroring the conditions
    /// it applies itself. The two-column layouts ask before reserving a column
    /// for buttons: half a canvas left empty reads worse than one wide column.
    private var drawsActionButtons: Bool {
        #if canImport(WidgetKit)
        guard widgetRenderingMode == .fullColor else { return false }
        #endif
        return card.actions?.contains(where: \.isSafeFromWidget) ?? false
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let icon = card.icon { Image(systemName: icon) }
                Text(card.title).font(.caption2).fontWeight(.medium)
                if card.isFromGuestLink { guestBadge }
            if card.showsSampleBadge { sampleBadge }
                Spacer(minLength: 0)
                if let statusIcon = card.statusIcon {
                    Image(systemName: statusIcon).font(.caption2)
                }
            }
            Text(card.value ?? card.status.label)
                .font(.headline)
            if card.template == .breakdown, let items = card.items, !items.isEmpty {
                CompositionBarView(items: items, tint: .primary, height: 8)
            } else if card.template == .history, let items = card.items, !items.isEmpty {
                StatusStripView(items: items, limit: 12, height: 8)
            } else if card.template == .chart, let chart = card.chart, chart.isRenderable {
                // The accessory families render monochrome, so the tint would
                // be flattened anyway; an unfilled line stays legible.
                SparklineView(
                    chart: chart,
                    tint: .primary,
                    lineWidth: 1.5,
                    showsArea: false,
                    maxPoints: 24
                )
                .frame(height: 14)
            } else if let subtitle = card.subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var circularView: some View {
        #if os(tvOS)
        EmptyView()
        #else
        Gauge(value: card.progressValue ?? 0) {
            if let icon = card.icon { Image(systemName: icon) }
        } currentValueLabel: {
            Text(card.value ?? "—").font(.caption).lineLimit(1)
        }
        .gaugeStyle(.accessoryCircular)
        #endif
    }

    private var inlineView: some View {
        HStack(spacing: 4) {
            if let icon = card.icon { Image(systemName: icon) }
            Text("\(card.title): \(card.value ?? card.status.label)\(card.unit.map { " \($0)" } ?? "")")
        }
    }

    private var appView: some View {
        VStack(alignment: .leading, spacing: 16) {
            appHeader
            appContent

            if density != .compact {
                appControls

                if let deadline = card.deadline {
                    Label {
                        Text(deadline, style: .relative)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                }
                Label(
                    card.updatedAt.formatted(.relative(presentation: .named)),
                    systemImage: "arrow.clockwise"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            }
        }
        .padding(20)
        .background(appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 8)
    }

    private var appHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            ZStack {
                Circle()
                    .fill(card.status.tint.opacity(0.16))
                Image(systemName: card.icon ?? "square.grid.2x2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(card.status.tint)
                    .accessibilityHidden(true)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                producerLine(font: .caption)
            }

            if card.isFromGuestLink { guestBadge }
            if card.showsSampleBadge { sampleBadge }

            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }

            if let statusIcon = card.statusIcon {
                Image(systemName: statusIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(card.status.tint)
            }

            if card.needsUserAttention {
                AttentionBadge()
            } else {
                StatusBadge(status: card.status, compact: true)
            }

            if density == .compact {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.title), Status: \(card.status.label)")
        .accessibilityInputLabels([card.title])
    }

    @ViewBuilder
    private var appContent: some View {
        switch card.template {
        case .list:
            appListRows
        case .progress:
            appValue
            if let progress = card.progressValue {
                ProgressView(value: progress)
                    .tint(card.status.tint)
            }
            if let subtitle = card.subtitle {
                appSubtitle(subtitle)
            }
        case .chart:
            appValue
            if let subtitle = card.subtitle {
                appSubtitle(subtitle)
            }
            if showsAppChart {
                sparkline(height: density == .compact ? 56 : 110, lineWidth: 2.5)
                chartSupplement(
                    legendLimit: density == .compact ? 2 : 4,
                    labelLimit: density == .compact ? 0 : 6,
                    font: .caption
                )
            }
        case .history:
            appValue
            if let subtitle = card.subtitle {
                appSubtitle(subtitle)
            }
            statusStrip(limit: 20, height: 18)
            if density != .compact {
                appListRows
            }
        case .breakdown:
            appValue
            if let subtitle = card.subtitle {
                appSubtitle(subtitle)
            }
            compositionBar(height: 20)
            if density != .compact {
                appBreakdownRows
            }
        case .briefing:
            appValue
            if let subtitle = card.subtitle {
                appSubtitle(subtitle)
            }
            appBriefingSections(max: density == .compact ? 1 : 8)
        case .summary, .action:
            appValue
            if let subtitle = card.subtitle {
                appSubtitle(subtitle)
            }
        }
    }

    private var appValue: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 5))
        return VStack(alignment: .leading, spacing: 4) {
            layout {
                Text(card.value ?? "—")
                    .font(.largeTitle.weight(.semibold))
                    .fontDesign(.rounded)
                    .minimumScaleFactor(0.6)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if let unit = card.unit {
                    Text(unit)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            comparisonLine(font: .subheadline)
        }
    }

    private func appSubtitle(_ subtitle: String) -> some View {
        Text(subtitle)
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : (density == .compact ? 1 : 3))
    }

    private func briefingLead(subtitleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            bigValue()
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLines)
            }
        }
    }

    @ViewBuilder
    private func briefingSections(max: Int, lineLimit: Int = 2, fills: Bool = false) -> some View {
        if max > 0, let sections = card.briefing?.sections, !sections.isEmpty {
            if fills {
                GeometryReader { proxy in
                    // Same bargain the row stacks make: a line spent saying
                    // what was left out, but only when two or more sections
                    // went and the plan can still afford them a line each.
                    let first = briefingPlan(sections.count, ceiling: max, height: proxy.size.height)
                    let dropped = Swift.min(sections.count, max) - first.sections
                    let saysMore = dropped >= 2
                    let plan = saysMore
                        ? briefingPlan(
                            sections.count,
                            ceiling: max,
                            height: proxy.size.height - truncationLineUnit
                        )
                        : first
                    let hidden = sections.count - plan.sections
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(sections.prefix(plan.sections)) { section in
                            briefingSection(section, font: .caption, lineLimit: plan.lines)
                        }
                        if saysMore, hidden > 0 {
                            truncationLine(hidden)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(sections.prefix(max)) { section in
                        briefingSection(section, font: .caption2, lineLimit: lineLimit)
                    }
                }
            }
        }
    }

    private func briefingPlan(_ sectionCount: Int, ceiling: Int, height: CGFloat) -> BriefingFill.Plan {
        BriefingFill.plan(
            height: height,
            sectionCount: Swift.min(sectionCount, ceiling),
            lineHeight: briefingLineUnit,
            labelHeight: briefingLabelUnit,
            spacing: 5
        )
    }

    private func briefingSection(
        _ section: DashboardBriefingSection,
        font: Font,
        lineLimit: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let label = section.label, !label.isEmpty {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(card.status.tint)
                    .lineLimit(1)
            }
            Text(section.text)
                .font(font)
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
        }
    }

    @ViewBuilder
    private func appBriefingSections(max: Int) -> some View {
        if let sections = card.briefing?.sections, !sections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sections.prefix(max)) { section in
                    VStack(alignment: .leading, spacing: 3) {
                        if let label = section.label, !label.isEmpty {
                            Text(label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(card.status.tint)
                        }
                        Text(section.text)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var appListRows: some View {
        if let items = card.items, !items.isEmpty {
            let fractions = RankedRows.fractions(for: items)
            VStack(spacing: 10) {
                ForEach(items.prefix(density == .compact ? 3 : 10)) { item in
                    rowLink(item) {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(spacing: 12))
                        layout {
                            SemanticFlowIcon(item.semantic)
                            Text(item.title)
                                .font(.subheadline)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            if item.deepLink != nil {
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            if !dynamicTypeSize.isAccessibilitySize {
                                Spacer(minLength: 8)
                            }
                            if let value = item.displayValue {
                                Text(value)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(alignment: .leading) {
                            if let fraction = fractions?[item.id] {
                                RankedRowBar(fraction: fraction, tint: RankedRows.tint(for: item, base: card.status.tint))
                            }
                        }
                    }
                }
            }
        } else {
            Text("No items")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var appControls: some View {
        let actions = card.actions ?? []
        if (!actions.isEmpty && appActionHandler != nil) || card.deepLink != nil {
            Divider()

            VStack(spacing: 10) {
                if let appActionHandler {
                    ForEach(actions) { action in
                        let isBusy = appActionIsBusy?(action) ?? false
                        Button {
                            appActionHandler(action)
                        } label: {
                            Label(isBusy ? "Running…" : action.label, systemImage: actionIcon(action))
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isBusy)
                        .accessibilityValue(isBusy ? "In progress" : "")
                        .buttonStyle(.borderedProminent)
                        .tint(action.role == .destructive ? .red : card.status.tint)
                        .controlSize(.large)
                    }
                }

                if let deepLink = card.deepLink {
                    Link(destination: deepLink) {
                        Label("Open link", systemImage: "arrow.up.forward.app")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(card.status.tint)
                    .controlSize(.large)
                }
            }
        }
    }

    private var appBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                card.status.tint.opacity(0.06),
                Color.primary.opacity(0.03)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func actionIcon(_ action: ActionDefinition) -> String {
        action.role == .destructive ? "exclamationmark.triangle.fill" : "bolt.fill"
    }

    /// Value plus subtitle above a plot. A plot this size carries no axis
    /// labels at all, so whatever context the card has is in its subtitle —
    /// which is why this keeps it even where `summary` drops it for space.
    private var chartHeadline: some View {
        VStack(alignment: .leading, spacing: 2) {
            bigValue()
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func compositionBar(height: CGFloat) -> some View {
        if let items = card.items, !items.isEmpty {
            CompositionBarView(items: items, tint: card.status.tint, height: height)
        }
    }

    /// A key for the bar, in the bar's own order. Each row shows the item's own
    /// `value` when it has one and the computed share otherwise, so a publisher
    /// can label segments in its own units without restating the percentages.
    @ViewBuilder
    private func breakdownLegend(max limit: Int, fills: Bool = false) -> some View {
        let shares = CompositionBarView.shares(of: card.items ?? [])
        if limit > 0 && !shares.isEmpty {
            let visible = Array(shares.prefix(limit).enumerated())
            if fills {
                GeometryReader { proxy in
                    let fit = ListRowFill.fit(
                        height: proxy.size.height,
                        unit: legendRowUnit,
                        itemCount: shares.count,
                        ceiling: limit,
                        indicatorHeight: truncationLineUnit
                    )
                    let rows = Array(visible.prefix(fit.rows))
                    let slot = ListRowFill.slot(
                        height: proxy.size.height - (fit.hidden > 0 ? truncationLineUnit : 0),
                        rows: rows.count,
                        unit: legendRowUnit
                    )
                    let font = ListRowFill.font(
                        slot: slot,
                        width: proxy.size.width,
                        unit: legendRowUnit,
                        ladder: .legend
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.element.item.id) { index, entry in
                            legendRow(index: index, entry: entry, font: font)
                                .frame(maxHeight: slot)
                        }
                        if fit.hidden > 0 {
                            truncationLine(fit.hidden)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(visible, id: \.element.item.id) { index, entry in
                        legendRow(index: index, entry: entry, font: .caption2)
                    }
                }
            }
        }
    }

    /// What the canvas could not hold. Deliberately quiet — it is chrome, not
    /// data — and deliberately present: the Live Activity has always said
    /// `+N more`, and a widget row count that now depends on the device and the
    /// reader's text size needs it more than a fixed one did.
    private func truncationLine(_ hidden: Int) -> some View {
        Text("+\(hidden) more")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(hidden) more not shown")
    }

    private func legendRow(
        index: Int,
        entry: (item: DashboardItem, share: Double),
        font: Font
    ) -> some View {
        HStack(spacing: 5) {
            SeriesSwatch(
                index: index,
                color: CompositionBarView.tint(
                    for: entry.item,
                    index: index,
                    base: card.status.tint,
                    increasedContrast: colorSchemeContrast == .increased
                ),
                size: 6,
                differentiateWithoutColor: differentiateWithoutColor
            )
            Text(entry.item.title)
                .font(font)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(legendValue(entry.item, share: entry.share))
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var appBreakdownRows: some View {
        let shares = CompositionBarView.shares(of: card.items ?? [])
        if shares.isEmpty {
            Text("No items")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 10) {
                ForEach(Array(shares.enumerated()), id: \.element.item.id) { index, entry in
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(spacing: 10))
                    layout {
                        SeriesSwatch(
                            index: index,
                            color: CompositionBarView.tint(
                                for: entry.item,
                                index: index,
                                base: card.status.tint,
                                increasedContrast: colorSchemeContrast == .increased
                            ),
                            size: 8,
                            differentiateWithoutColor: differentiateWithoutColor
                        )
                        Text(entry.item.title)
                            .font(.subheadline)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer(minLength: 8)
                        }
                        Text(legendValue(entry.item, share: entry.share))
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    private func legendValue(_ item: DashboardItem, share: Double) -> String {
        if let value = item.displayValue { return value }
        return "\(Int((share * 100).rounded()))%"
    }

    /// Nothing is drawn without items, the way `chart` draws nothing without a
    /// series — the headline value carries the card on its own.
    @ViewBuilder
    private func statusStrip(limit: Int, height: CGFloat) -> some View {
        if let items = card.items, !items.isEmpty {
            StatusStripView(items: items, limit: limit, height: height)
        }
    }

    /// Nothing is drawn when the series is missing or too short to be a trend;
    /// the card's headline value carries it instead.
    @ViewBuilder
    private func sparkline(
        height: CGFloat,
        lineWidth: CGFloat = 2,
        maxPoints: Int? = nil
    ) -> some View {
        if let chart = card.chart, chart.isRenderable {
            SparklineView(
                chart: chart,
                tint: card.status.tint,
                lineWidth: lineWidth,
                maxPoints: maxPoints
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
    }

    @ViewBuilder
    private func chartSupplement(
        legendLimit: Int,
        labelLimit: Int,
        font: Font = .caption2
    ) -> some View {
        if let chart = card.chart,
           (chart.series?.isEmpty == false
            || chart.labels?.isEmpty == false
            || chart.referenceMetadata != nil) {
            ChartSupplementView(
                chart: chart,
                tint: card.status.tint,
                legendLimit: legendLimit,
                labelLimit: labelLimit,
                font: font
            )
        }
    }

    /// A plot that grows into whatever height the layout has left over, never
    /// falling below `minHeight`. A fixed height is right where the card is
    /// mostly text, but a large widget is over twice the height of a medium one
    /// and a pinned plot leaves the bottom third of the card empty.
    @ViewBuilder
    private func sparkline(
        minHeight: CGFloat,
        lineWidth: CGFloat = 2,
        maxPoints: Int? = nil
    ) -> some View {
        if let chart = card.chart, chart.isRenderable {
            SparklineView(
                chart: chart,
                tint: card.status.tint,
                lineWidth: lineWidth,
                maxPoints: maxPoints
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight, maxHeight: .infinity)
        }
    }

    private var actionSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            bigValue()
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// Wraps a row in a `Link` where one row can be addressed on its own.
    ///
    /// Only medium and large Home Screen widgets can: everywhere else the whole
    /// widget is a single tap target owned by `widgetURL`, and a `Link` there
    /// is silently inert — the card's own `deepLink` is what opens. In the app
    /// every row can be a link.
    private func rowLink<Content: View>(
        _ item: DashboardItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if let destination = item.deepLink, addressableRows {
                Link(destination: destination) { content() }
            } else {
                content()
            }
        }
    }

    private var addressableRows: Bool {
        switch context {
        case .app, .widgetMedium, .widgetLarge, .widgetExtraLarge, .widgetExtraLargePortrait: return true
        default: return false
        }
    }

    /// `dropping` skips the rows a previous column already drew. The bar
    /// fractions stay computed over *all* items, so the two columns of an
    /// extra-large list remain comparable to each other rather than each
    /// rescaling to its own tallest row.
    ///
    /// `fills` hands the list the canvas's spare height instead of leaving it
    /// to a trailing `Spacer`. `max` is then a readability ceiling rather than
    /// a size estimate: the number of rows actually drawn comes from measuring
    /// the room, and the rows spread across it. The caps used to be constants
    /// picked well under what fits — a medium widget drew three rows into room
    /// for six — so a six-item card showed half its data above a third of a
    /// card left blank, and a large one showed all six as a small block under
    /// the header with the rest of the card empty.
    @ViewBuilder
    private func listRows(max: Int, dropping: Int = 0, fills: Bool = false) -> some View {
        if let items = card.items, !items.isEmpty {
            let fractions = RankedRows.fractions(for: items)
            let visible = Array(items.dropFirst(dropping).prefix(max))
            if fills {
                GeometryReader { proxy in
                    // How many rows the canvas holds, how many items that
                    // leaves out, then how tall each row may grow and what
                    // size it reads at.
                    let fit = ListRowFill.fit(
                        height: proxy.size.height,
                        unit: listRowUnit,
                        itemCount: items.count - dropping,
                        ceiling: max,
                        indicatorHeight: truncationLineUnit
                    )
                    let rows = Array(visible.prefix(fit.rows))
                    let slot = ListRowFill.slot(
                        height: proxy.size.height - (fit.hidden > 0 ? truncationLineUnit : 0),
                        rows: rows.count,
                        unit: listRowUnit
                    )
                    let font = ListRowFill.font(
                        slot: slot,
                        width: proxy.size.width,
                        unit: listRowUnit
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { item in
                            listRow(item, font: font, fractions: fractions)
                                .frame(maxHeight: slot)
                        }
                        if fit.hidden > 0 {
                            truncationLine(fit.hidden)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(visible) { item in
                        listRow(item, font: .caption, fractions: fractions)
                    }
                }
            }
        } else {
            Text("No items").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func listRow(
        _ item: DashboardItem,
        font: Font,
        fractions: [String: Double]?
    ) -> some View {
        rowLink(item) {
            HStack {
                SemanticFlowIcon(item.semantic)
                Text(item.title).font(font).lineLimit(1)
                Spacer()
                if let v = item.displayValue {
                    Text(v)
                        .font(font)
                        .foregroundStyle(.primary)
                        // A filled row is as tall as its slot, which is room a
                        // long value will otherwise wrap into — one row then
                        // reads as two, and the row under it moves.
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 3)
            .background(alignment: .leading) {
                if let fraction = fractions?[item.id] {
                    RankedRowBar(fraction: fraction, tint: RankedRows.tint(for: item, base: card.status.tint))
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(max: Int) -> some View {
        #if canImport(WidgetKit)
        if max <= 0 || widgetRenderingMode != .fullColor {
            EmptyView()
        } else if let actions = card.actions, !actions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(actions.prefix(max)) { action in
                    if action.isSafeFromWidget {
                        Button(intent: RunDashboardActionIntent(actionId: action.id, cardId: card.id)) {
                            Text(action.label)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if let deepLink = card.deepLink {
                        Link(destination: deepLink) {
                            Text(action.label)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        #else
        EmptyView()
        #endif
    }

}

private struct CardAccessibilityModifier: ViewModifier {
    let card: DashboardCard
    let combinesChildren: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if combinesChildren {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(CardAccessibilitySummary.summary(for: card)))
                // What someone *says* to activate this, as distinct from what
                // is read to them. The label is a sentence — "Solar is 3.4 kW.
                // Status: good." — and Voice Control matches on the label, so
                // "Tap Solar" found nothing on a card whose name is written
                // across the top of it. The spoken description is unchanged;
                // this only adds the name to what will activate it.
                .accessibilityInputLabels([card.title])
        } else {
            content
        }
    }
}

extension DashboardCard {
    var progressValue: Double? {
        // An explicit `progress` wins on every template, and frees `value` to be
        // the display string it is everywhere else on the card.
        if let progress { return min(max(progress, 0), 1) }
        switch template {
        case .progress:
            // How a progress card said it before `progress` existed: the
            // fraction parsed out of `value`, with anything above 1 read as a
            // percentage. Kept so cards from producers that predate the field
            // keep drawing their bar.
            guard let v = value, let d = Double(v) else { return nil }
            return d > 1 ? d / 100 : d
        case .chart:
            // The circular accessory is a gauge and has no room for a plot. The
            // latest point, placed in the series' own range, is the only needle
            // position that means anything for a chart card.
            return chart?.normalizedPoints.last
        default:
            return nil
        }
    }

    /// Whether `value` is a label rather than the fraction itself. Only true
    /// once a card sends `progress`, which is what lets a progress card show a
    /// bar and a headline number at the same time.
    var progressValueIsLabel: Bool {
        progress != nil && value != nil
    }
}

public struct CardFallbackView: View {
    public enum Reason {
        case noCardSelected
        case noCachedData
        case stale(Date)
        case filtered(String)
        case error(String)
    }

    public let reason: Reason
    public init(reason: Reason) { self.reason = reason }

    public var body: some View {
        VStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title).font(.caption).foregroundStyle(.secondary)
            // Secondary, not tertiary: every one of these details is an
            // instruction ("Open 00Widget and refresh"), and it is the only
            // sentence on a widget that has nothing else to show.
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(8)
    }

    private var iconName: String {
        switch reason {
        case .noCardSelected: return "square.dashed"
        case .noCachedData: return "icloud.slash"
        case .stale: return "clock.badge.exclamationmark"
        case .filtered: return "line.3.horizontal.decrease.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch reason {
        case .noCardSelected: return "Pick a card"
        case .noCachedData: return "No data"
        case .stale: return "Stale"
        case .filtered: return "No matching cards"
        case .error: return "Error"
        }
    }

    private var detail: String? {
        switch reason {
        case .noCardSelected: return "Long-press to configure."
        case .noCachedData: return "Open 00Widget and refresh."
        case .stale(let d): return "Updated \(d.formatted(.relative(presentation: .named)))"
        case .filtered(let filter): return "No cached cards match \(filter)."
        case .error(let m): return m
        }
    }
}
