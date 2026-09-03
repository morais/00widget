import SwiftUI

/// Type sizes for a screen read from a sofa.
///
/// tvOS 26 has no Dynamic Type setting, so what the app draws is what is read.
/// tvOS 27 adds one. The fixed measurements below remain the standard-size
/// design inputs, but `tvScaledSystemFont` scales them relative to semantic
/// styles when the platform begins publishing a larger text preference.
///
/// The trap is `minimumScaleFactor`, which shrinks past that floor silently. A
/// 34pt headline at 0.65 renders at 22.1pt — under the floor, for the largest
/// number on the card. Dashboard values therefore use the same 44pt base size
/// whether or not a plot follows them.
enum TVTypography {
    static let valueSize: CGFloat = 44
    static let chartValueSize = valueSize
    /// Supporting context below a chart value. Keep this explicit: tvOS's
    /// semantic callout curve can make supporting text physically taller than
    /// a custom value even when its nominal point size is smaller.
    static let chartSubtitleSize: CGFloat = 26
    /// Caption 2, the smallest style tvOS defines.
    static let floor: CGFloat = 23

    /// `preferred`, unless shrinking that far would go under the floor.
    ///
    /// Raising the floor is the whole job here, so a size that was already
    /// safe keeps the scale it had: 44pt at 0.65 bottoms out at 28.6pt and is
    /// left alone, while 34pt at 0.65 would reach 22.1pt and is clamped to
    /// 0.68 instead.
    static func scale(_ preferred: CGFloat, for size: CGFloat) -> CGFloat {
        max(preferred, min(1, floor / size))
    }
}

/// The widget card's box, which is a fixed size so a row of them lines up.
///
/// Fixed is the trap as well as the point. A `VStack` given less height than it
/// needs does not compress — it overflows, centred, straight through the
/// padding around it, and nothing about that is visible in a build or a test.
/// At 220 points a `chart` card's four stacked elements came to more than the
/// box held, so the plot sat flush against the card's bottom edge with no inset
/// at all; the Live Activity card had already hit this and answered it with a
/// `minHeight`, which a grid row cannot use without going ragged.
///
/// So the height is derived rather than chosen: it is what the tallest template
/// actually measures at these type sizes — header, headline, subtitle and a
/// 46-point plot, about 196 points — plus the inset on both sides. Re-measure
/// it if any of those change, and check a screenshot
/// rather than the build, which cannot see an overflow.
enum TVCardMetrics {
    static let verticalPadding: CGFloat = 28
    static let height: CGFloat = 252
    /// The same measurement at the top of the non-accessibility range.
    ///
    /// Derived from `height` rather than chosen beside it: the content is
    /// `height` less both insets, that content is essentially type and so
    /// grows with the type ramp — about 1.35x by `.xxxLarge` — and then the
    /// insets are given back. Re-measure it the way `height` was measured if
    /// the type sizes change, and check a screenshot, because the compiler
    /// cannot see an overflow.
    static let enlargedHeight: CGFloat =
        (height - verticalPadding * 2) * 1.35 + verticalPadding * 2
}

struct TVDashboardView: View {
    @EnvironmentObject var env: TVEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Owned by `TVRootView`, which presents the cover: see the note there.
    @Binding var showingSettings: Bool
    /// What the viewer has opened. Every card and every activity opens one:
    /// the grid cell is a summary, and everything that does not fit in it —
    /// the whole list, the whole history, the action buttons, the QR code for
    /// the link — lives behind this.
    @State private var selectedDetail: TVDetailSubject?

    private var widgetColumnCount: Int {
        TVTextScale(dynamicTypeSize).widgetColumnCount
    }

    var body: some View {
        VStack(spacing: 32) {
            header
            content
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [Color.black.opacity(0.2), Color.accentColor.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        // The cover does not make its presenter inert: with a detail panel up,
        // the dashboard behind it — every card, and the Settings button — was
        // still enumerable by assistive technology. Same reasoning as the
        // Settings cover in `TVRootView`.
        .accessibilityHidden(selectedDetail != nil)
        .fullScreenCover(item: $selectedDetail) { subject in
            TVDetailView(subject: subject)
                .environmentObject(env)
        }
        // The header's sync error is not focusable and nothing draws attention
        // to it appearing — on a television left running on a wall, a
        // dashboard that quietly stopped updating looks exactly like one that
        // has nothing new to say.
        .onChange(of: env.lastSyncError) { _, error in
            if let error { AccessibilityAnnouncement.post(error) }
        }
    }

    private var header: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dashboard")
                    .font(.largeTitle.weight(.bold))
                syncStatus
            }

            Spacer()

            if env.isRefreshing {
                ProgressView()
                    .controlSize(.large)
            }

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
        }
        // The whole reason focus can leave the grid. tvOS moves focus by
        // geometry, and nothing in the scrolling content lined up with a
        // header button sitting above it: pressing Up from the top row of
        // widgets did nothing, ten times over, so Settings — and with it sign
        // out, the diagnostics, and the account deletion Apple requires an app
        // to offer — could not be reached at all. A focus section is
        // considered by direction rather than by alignment.
        //
        // The Live Activity card used to paper over this with an
        // `onMoveCommand` that shoved focus into the header on Up. That worked
        // only for the one card type that had it, which is why a dashboard of
        // widgets and no activities — the ordinary case — was the broken one.
        .focusSection()
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let error = env.lastSyncError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if let lastSyncAt = env.lastSyncAt {
            RelativeTimeClock(since: lastSyncAt) {
                Text("Updated \(lastSyncAt.formatted(.relative(presentation: .named)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if !env.hasCompletedInitialSync {
            Text("Loading dashboard…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("Your agent widgets")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if env.cards.isEmpty && env.liveActivities.isEmpty && !env.hasCompletedInitialSync {
            initialLoadingState
        } else if env.cards.isEmpty && env.liveActivities.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 42) {
                    if !env.liveActivities.isEmpty {
                        dashboardSection(
                            title: "Ongoing Activities",
                            icon: "waveform",
                            items: env.liveActivities,
                            columns: 1
                        ) { activity in
                            TVLiveActivityCardView(
                                activity: activity,
                                open: { selectedDetail = .activity(activity) }
                            )
                        }
                    }

                    if !env.cards.isEmpty {
                        dashboardSection(
                            title: "Widgets",
                            icon: "square.grid.2x2",
                            items: env.cards,
                            columns: widgetColumnCount
                        ) { card in
                            TVDashboardCardView(
                                card: card,
                                open: { selectedDetail = .card(card) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
    }

    private func dashboardSection<Item: Identifiable, Content: View>(
        title: String,
        icon: String,
        items: [Item],
        columns: Int,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(title, systemImage: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            grid(items, columns: columns, content: content)
        }
    }

    /// Rows assembled by hand rather than by a `LazyVGrid`, because tvOS moves
    /// focus only to views that exist and a lazy grid does not build what is
    /// off screen. Nothing had ever fallen far enough below the fold to show
    /// it: when the Live Activity card grew tall enough to push the Widgets
    /// row past the bottom of the screen, pressing down found no focusable
    /// view, so focus stayed put, so the scroll view never scrolled, so the
    /// row it would have built stayed unreachable — the whole section
    /// unreachable with no way back to it. A dashboard holds a handful of
    /// cards, so building every one of them up front costs nothing.
    private func grid<Item: Identifiable, Content: View>(
        _ items: [Item],
        columns: Int,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        let rows = stride(from: 0, to: items.count, by: columns).map { start in
            Array(items[start..<min(start + columns, items.count)])
        }
        return VStack(alignment: .leading, spacing: 40) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 40) {
                    ForEach(row) { item in
                        content(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // A short last row keeps its cards the width they have in a
                    // full one rather than stretching to share the space.
                    if row.count < columns {
                        ForEach(row.count..<columns, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var initialLoadingState: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)
            Text("Loading dashboard")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.dashed")
                .tvScaledSystemFont(size: 96, relativeTo: .largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Nothing to show yet")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Text("Publish a widget or start a Live Activity from your agent.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TVLiveActivityCardView: View {
    let activity: LiveActivitySession
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Two columns rather than one row per item. Six rows is the published
    /// maximum, so the grid is at most three rows tall, and each row keeps
    /// roughly the proportions the phone card gives it. Stacking them full
    /// width would leave the same empty band across the middle of the card
    /// that drawing no items at all left.
    private var itemColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
            count: dynamicTypeSize.usesTVLargeTextLayout ? 1 : 2
        )
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                header
                let summaryLayout = dynamicTypeSize.usesTVLargeTextLayout
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                summaryLayout {
                    VStack(alignment: .leading, spacing: 8) {
                        if let subtitle = activity.subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .tvReadableText(standardLineLimit: 2)
                        }
                        freshness
                    }
                    Spacer(minLength: 12)
                    trailingValue
                        .frame(
                            maxWidth: dynamicTypeSize.usesTVLargeTextLayout ? .infinity : nil,
                            alignment: dynamicTypeSize.usesTVLargeTextLayout ? .leading : .trailing
                        )
                }

                // A composite activity says what it is doing through its
                // rows; dropping them left this card showing a title and a
                // number where the phone showed four.
                if !presentationItems.isEmpty {
                    LazyVGrid(columns: itemColumns, alignment: .leading, spacing: 16) {
                        ForEach(presentationItems) { item in
                            TVLiveActivityItemRow(item: item)
                        }
                    }
                }

                if let chart = activity.chart, chart.isRenderable {
                    // Taller than the widget card's plot: this one has the
                    // full width of the screen, and a 46-point trace read
                    // as a flat line from a sofa.
                    SparklineView(chart: chart, tint: activity.tint, lineWidth: 4)
                        .frame(height: 72)
                } else if let progress = activity.progress,
                          activity.endsAt == nil,
                          // Rows replace the progress bar, as they do on
                          // every other surface.
                          presentationItems.isEmpty {
                    ProgressView(value: max(0, min(progress, 1)))
                        .tint(activity.tint)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A floor, not a fixed height. The header, value row, chart,
            // and inter-row spacing need enough height for the requested
            // inset to survive layout: at 220 points SwiftUI compressed the
            // vertical padding to almost zero, leaving the focused card
            // against its content. Item rows then need more room than any
            // one number can reserve, so the card grows past the floor
            // rather than clipping them.
            .frame(minHeight: TVTextScale(dynamicTypeSize).liveActivityMinimumHeight)
            .contentShape(RoundedRectangle(cornerRadius: 24))
            // See the note in `TVDashboardCardView`: this has to sit inside
            // the button's label to replace what the button synthesizes.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilitySummary))
        }
        .buttonStyle(.card)
        .accessibilityHint("Opens the full activity")
    }

    /// The shared summary, then a line per item. A phone can leave the rows as
    /// their own elements because it scrolls through them; the television draws
    /// the whole card as one focusable unit, so anything left out of this label
    /// is not read anywhere — and on a composite activity the rows *are* the
    /// content.
    private var accessibilitySummary: String {
        ([LiveActivityAccessibilitySummary.summary(for: activity)]
            + presentationItems.map(LiveActivityAccessibilitySummary.summary(for:)))
            .joined(separator: ". ")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.detailIconName)
                .font(.title2)
                .foregroundStyle(activity.tint)
            // What the activity is doing right now, beside what it is.
            if let statusIcon = activity.semanticStatusIcon {
                Image(systemName: statusIcon)
                    .font(.headline)
                    .foregroundStyle(activity.tint)
            }
            Text(activity.title)
                .font(.title3.weight(.semibold))
                .tvReadableText(
                    standardLineLimit: 1,
                    largeTextLineLimit: 2,
                    standardMinimumScaleFactor: 0.75
                )
            Spacer(minLength: 8)
            Text(activity.needsUserAttention ? "Needs you" : activity.state.capitalized)
                .font(.callout.weight(.semibold))
                .tvReadableText(largeTextLineLimit: 2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(activity.tint.opacity(0.18)))
                .foregroundStyle(activity.tint)
        }
    }

    private var freshness: some View {
        TVFreshness(updatedAt: activity.updatedAt, isStale: { activity.isStale }, font: .callout)
    }

    @ViewBuilder
    private var trailingValue: some View {
        if let endsAt = activity.endsAt {
            LiveActivityCountdownText(
                endsAt: endsAt,
                granularity: activity.countdownGranularity
            )
            .tvScaledSystemFont(
                size: 32,
                relativeTo: .title3,
                weight: .semibold,
                design: .rounded
            )
            .monospacedDigit()
            .tvReadableText()
        } else if let value = activity.value {
            VStack(
                alignment: dynamicTypeSize.usesTVLargeTextLayout ? .leading : .trailing,
                spacing: 0
            ) {
                Text(value)
                    .tvScaledSystemFont(
                        size: 40,
                        relativeTo: .title2,
                        weight: .semibold,
                        design: .rounded
                    )
                    .tvReadableText()
                if let unit = activity.unit {
                    Text(unit)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
        } else if !activeItems.isEmpty {
            // A derived stand-in for a value the producer did not send, and
            // only ever that: an explicit `value` above keeps the slot.
            Text("\(activeItems.count) active")
                .font(.title3.weight(.semibold))
        } else {
            Text(activity.state.capitalized)
                .font(.title3.weight(.semibold))
        }
    }

    private var activeItems: [LiveActivityItem] {
        activity.activeItems
    }

    private var presentationItems: [LiveActivityItem] {
        activity.budgetedPresentationItems(fillingTo: 3)
    }

}

/// The phone's activity row at television scale. Kept beside the card rather
/// than shared with `LiveActivitiesView`: that one is compiled into the app
/// target only, and the two surfaces size their type independently.
struct TVLiveActivityItemRow: View {
    let item: LiveActivityItem
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: item.icon ?? "circle.fill")
                    .font(.title3)
                    .foregroundStyle(item.tint())
                    .frame(width: 32)
                if let statusIcon = item.statusIcon {
                    Image(systemName: statusIcon)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        SemanticFlowIcon(item.semantic, font: .callout)
                        Text(item.title)
                            .font(.headline)
                            .tvReadableText(largeTextLineLimit: 2)
                    }
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .tvReadableText(largeTextLineLimit: 2)
                    }
                }

                Spacer(minLength: 12)

                if let value = item.value {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value)
                            .font(.title3.weight(.semibold))
                            .tvReadableText()
                        if let unit = item.unit {
                            Text(unit)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .tvReadableText()
                        }
                    }
                } else if let status = item.status {
                    Text(status.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(
                            VisualAccommodations.textTint(
                                status.tint,
                                increasedContrast: colorSchemeContrast == .increased
                            )
                        )
                        .tvReadableText()
                }
            }

            if let progress = item.progress {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(.linear)
                    .tint(item.tint())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

private struct TVDashboardCardView: View {
    let card: DashboardCard
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var textScale: TVTextScale { TVTextScale(dynamicTypeSize) }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                header

                switch card.template {
                case .list:
                    listContent
                case .progress:
                    valueContent
                    if let progress = card.progressValue {
                        ProgressView(value: progress)
                            .tint(card.status.tint)
                    }
                case .chart:
                    chartContent
                case .history, .breakdown:
                    chartContent
                case .briefing:
                    valueContent
                    if let section = card.briefing?.sections.first {
                        Text(section.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .tvReadableText(standardLineLimit: 2, largeTextLineLimit: 4)
                    }
                case .summary, .action:
                    valueContent
                }

                if let deadline = card.deadline {
                    Label {
                        Text(deadline, style: .relative)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    // `.caption` is 25pt here. A countdown someone is meant
                    // to read across a room is not caption material.
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .tvReadableText()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, TVCardMetrics.verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: textScale.cardHeight)
            .frame(minHeight: textScale.cardMinimumHeight)
            .contentShape(RoundedRectangle(cornerRadius: 24))
            // Inside the label, not on the button. A button builds its own
            // label out of its children, keeping each child's
            // `accessibilityLabel` and dropping its `accessibilityValue` —
            // which is how `StatusBadge` contributed the bare word "Status"
            // and the status itself was never spoken. Collapsing the
            // children to one labelled element is what the button then has
            // to synthesize from; the same modifiers applied outside the
            // button are ignored.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilitySummary))
        }
        .buttonStyle(.card)
        .accessibilityHint(hint)
    }

    /// What pressing Select gets you, which now differs per card. Every card
    /// opens a panel, so every card is honestly a button — the previous rule,
    /// where a card with no `deepLink` had its button trait removed because
    /// pressing it did nothing at all, no longer applies and the modifier that
    /// did it is gone.
    private var hint: String {
        let extras = [
            (card.actions ?? []).isEmpty ? nil : "actions",
            card.deepLink == nil ? nil : "a QR code for its link",
        ].compactMap { $0 }
        return extras.isEmpty
            ? "Opens the full card"
            : "Opens the full card with " + extras.joined(separator: " and ")
    }

    /// The card is one focus stop and there is no detail screen behind it, so
    /// the plot has to be read here or nowhere. `listContent` draws three rows
    /// and `StatusStripView` fourteen pips; the label says what is on screen.
    private var accessibilitySummary: String {
        let detail = CardAccessibilitySummary.detail(
            for: card,
            rowLimit: card.template == .history ? 14 : 3
        )
        return detail.isEmpty
            ? CardAccessibilitySummary.summary(for: card)
            : CardAccessibilitySummary.summary(for: card) + " " + detail
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = card.icon {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(card.status.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.title3.weight(.semibold))
                    .tvReadableText(
                        standardLineLimit: 1,
                        largeTextLineLimit: 2,
                        standardMinimumScaleFactor: 0.75
                    )
                if let producer = card.producer {
                    HStack(spacing: 5) {
                        if let icon = producer.icon {
                            Image(systemName: icon).accessibilityHidden(true)
                        }
                        Text(producer.label)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .tvReadableText()
                }
            }
            Spacer(minLength: 8)
            if let statusIcon = card.statusIcon {
                Image(systemName: statusIcon)
                    .font(.headline)
                    .foregroundStyle(card.status.tint)
            }
            if card.needsUserAttention {
                Text("Needs you")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
            } else {
                StatusBadge(status: card.status, compact: true)
            }
        }
    }

    private var valueContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.displayValue ?? "—")
                .tvScaledSystemFont(
                    size: TVTypography.valueSize,
                    relativeTo: .title,
                    weight: .semibold,
                    design: .rounded
                )
                .tvReadableText(
                    standardMinimumScaleFactor: TVTypography.scale(
                        0.65,
                        for: TVTypography.valueSize
                    )
                )
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .tvReadableText(
                        largeTextLineLimit: 3,
                        standardMinimumScaleFactor: 0.75
                    )
            }
            comparisonLine
        }
    }

    @ViewBuilder
    private var comparisonLine: some View {
        if let comparison = card.comparison {
            HStack(spacing: 7) {
                Image(systemName: comparison.signal.symbolName).accessibilityHidden(true)
                Text(comparison.value).fontWeight(.semibold)
                Text(comparison.label).foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(comparison.signal.tint)
            .tvReadableText(largeTextLineLimit: 2)
        }
    }

    /// Value and subtitle above a plot — a sparkline for `chart`, status pips
    /// for `history`, a segmented bar for `breakdown`. The primary value keeps
    /// the same size as a non-chart card; the contextual subtitle is what steps
    /// down, preserving hierarchy without sacrificing the plot.
    @ViewBuilder
    private var chartContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.displayValue ?? "—")
                .tvScaledSystemFont(
                    size: TVTypography.chartValueSize,
                    relativeTo: .title2,
                    weight: .semibold,
                    design: .rounded
                )
                .tvReadableText(
                    standardMinimumScaleFactor: TVTypography.scale(
                        0.65,
                        for: TVTypography.chartValueSize
                    )
                )
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .tvScaledSystemFont(
                        size: TVTypography.chartSubtitleSize,
                        // Use the value's scaling curve. On tvOS, mixing the
                        // `.title2` curve above with `.caption` here makes a
                        // nominal 26pt caption physically taller than the
                        // nominal 34pt value at the standard setting.
                        relativeTo: .title2
                    )
                    .foregroundStyle(.secondary)
                    .tvReadableText(largeTextLineLimit: 2)
            }
            comparisonLine
        }
        // One plot per card, and the template picks it. `history` and
        // `breakdown` have their own — pips and a segmented bar — and every
        // other renderer in the app draws a sparkline for `chart` alone, so a
        // series sent on a `history` card was drawn here and nowhere else.
        // Stacking both is also what pushed this card past its own height.
        switch card.template {
        case .history:
            if let items = card.items, !items.isEmpty {
                StatusStripView(items: items, limit: 14, height: 20)
            }
        case .breakdown:
            if let items = card.items, !items.isEmpty {
                CompositionBarView(items: items, tint: card.status.tint, height: 22)
            }
        default:
            if let chart = card.chart, chart.isRenderable {
                SparklineView(chart: chart, tint: card.status.tint, lineWidth: 3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if let items = card.items, !items.isEmpty {
            let fractions = RankedRows.fractions(for: items)
            VStack(spacing: 8) {
                ForEach(items.prefix(3)) { item in
                    HStack {
                        SemanticFlowIcon(item.semantic, font: .callout)
                        Text(item.title)
                            .tvReadableText(largeTextLineLimit: 2)
                        Spacer()
                        if let value = item.displayValue {
                            Text(value)
                                .fontWeight(.semibold)
                                .foregroundStyle(
                                    item.status.map {
                                        VisualAccommodations.textTint(
                                            $0.tint,
                                            increasedContrast: colorSchemeContrast == .increased
                                        )
                                    } ?? AnyShapeStyle(.primary)
                                )
                        }
                    }
                    .font(.headline)
                    .padding(.horizontal, 6)
                    .background(alignment: .leading) {
                        if let fraction = fractions?[item.id] {
                            RankedRowBar(fraction: fraction, tint: RankedRows.tint(for: item, base: card.status.tint))
                        }
                    }
                }
            }
        } else {
            Text("No items")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}
