import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// One card in a grid of them, drawn small.
///
/// This is the second card renderer, beside `CardView`. It lives in
/// `Sources/Shared` for the same reason that one does: a renderer the
/// widget extension owns alone is a renderer no unit test can reach, and the
/// only thing left that can see it is a ten-minute capture run. The tvOS cell
/// learned this first — `TVDashboardCardContent` is in an app target, which
/// is what lets `TVCardFitTests` measure it — and `CardGridFitTests` is the
/// iOS counterpart, guarding the same class of defect on the surface the
/// four-cell App Store capture shows.
///
/// Its only environment dependency is `widgetRenderingMode`, behind the same
/// `canImport(WidgetKit)` guard `CardView` uses for it — `Sources/Shared` is
/// compiled into the tvOS app too, where that framework does not exist.
/// Everything else WidgetKit-shaped — the family, the timeline, the `Link`
/// around a cell — stays in `CardGridWidget`.
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

        /// Room between the cell's rounded background and its content. Read
        /// by the cell that draws it and by `CardGridMetrics`, which works out
        /// what is left for a line of text — the two disagreeing is how a
        /// subtitle budget goes stale.
        var padding: CGFloat { self == .compact ? 6 : 8 }
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
    #if canImport(WidgetKit)
    @Environment(\.widgetRenderingMode) private var renderingMode
    #endif

    /// A tinted or accented widget draws no card background: the system
    /// recolours everything in it, and a filled rectangle behind each cell
    /// becomes a solid block. WidgetKit is absent on tvOS, where the question
    /// does not arise and the fill is always right.
    private var drawsBackground: Bool {
        #if canImport(WidgetKit)
        return renderingMode == .fullColor
        #else
        return true
        #endif
    }

    var body: some View {
        ZStack {
            if drawsBackground {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background.secondary)
            }
            content
                .padding(style.padding)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(CardAccessibilitySummary.summary(for: card)))
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
                if card.status.needsAttention {
                    StatusBadge(status: card.status, compact: true)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(card.value ?? "—")
                    .font(.body.weight(.semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(.primary)
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
                if card.status.needsAttention {
                    StatusBadge(status: card.status, compact: true)
                }
            }
            band
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(card.value ?? "—")
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(.primary)
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
                if card.status.needsAttention {
                    StatusBadge(status: card.status, compact: true)
                }
            }
            band
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(card.value ?? "—")
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(.primary)
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

/// The room a grid cell has, worked out from the widget it is drawn in.
///
/// A cell's subtitle is a single line with no `minimumScaleFactor`, so it
/// truncates rather than shrinking, and an ellipsis is the one thing no
/// approved App Store image may contain. Nothing in a build or a suite sees
/// one — the four-cell capture shipped with two — so the arithmetic that
/// decides whether a string fits lives here, where `CardGridFitTests` can ask
/// it the same question the renderer does.
enum CardGridMetrics {
    /// WidgetKit's default content margin. It is applied outside the view, so
    /// the grid never subtracts it and a measurement of the grid alone would
    /// be 32 points too generous.
    static let widgetContentMargin: CGFloat = 16

    /// A small widget's two columns are tighter than everything else's.
    static func spacing(smallFamily: Bool) -> CGFloat { smallFamily ? 6 : 8 }

    /// What is left for a line of text in one cell of a `columns`-wide grid.
    static func contentWidth(
        widgetWidth: CGFloat,
        columns: Int,
        style: CardGridCell.Style,
        smallFamily: Bool = false
    ) -> CGFloat {
        let spacing = spacing(smallFamily: smallFamily)
        let available = widgetWidth - widgetContentMargin * 2 - spacing * CGFloat(columns - 1)
        return available / CGFloat(columns) - style.padding * 2
    }
}
