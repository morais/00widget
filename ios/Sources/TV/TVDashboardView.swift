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
    /// Supporting context below a chart value. Keep this explicit: tvOS's
    /// semantic callout curve can make supporting text physically taller than
    /// a custom value even when its nominal point size is smaller.
    static let chartSubtitleSize: CGFloat = 26
    /// The glyph beside a card's title. Deliberately *not* larger than the
    /// title it sits next to — see the note in `TVCardMetrics`.
    static let cardIcon: Font = .headline

    /// The status glyph that opens a Live Activity's item row, and the column
    /// it is aligned in.
    ///
    /// The column has to be at least as wide as the glyph. A `.frame(width:)`
    /// narrower than its content does not shrink or clip it — the glyph is
    /// centred and spills out of both sides — so a 57-point `.title3` dot in a
    /// 32-point column overhung by about 12 points at each end, which is more
    /// than the row's entire 12-point spacing. The dot sat against the word
    /// beside it and the row read as though the spacing had been forgotten.
    ///
    /// Measured: the widest symbol these rows draw is 47 points at
    /// `.headline`, which is also the size of the title beside it — the same
    /// rule `cardIcon` follows, and for the same reason. Re-measure with
    /// `TVRenderProbe.width(of:)` before changing either number, and change
    /// them together.
    static let rowIcon: Font = .headline
    static let rowIconColumn: CGFloat = 48
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
    static let horizontalPadding: CGFloat = 28
    /// Derived, and derived from the *trimmed* card rather than the card as a
    /// producer sends it — which is the distinction that had this number wrong
    /// twice. Measured, the tallest thing a cell draws is a `chart` card at
    /// 228 points: a one-line header, the headline, a comparison and a
    /// 46-point plot. It cannot go lower without giving up the comparison or
    /// the plot, and neither is optional on a card whose whole subject is a
    /// trend. 228 plus the inset on both sides is 284.
    ///
    /// Before trimming, the same measurement said 362 — which does not fit,
    /// because two full rows have to sit on 1080 lines and that caps a card at
    /// 304. So the order matters: decide what a cell draws, measure that, and
    /// size the box to it. Sizing the box to an untrimmed card is not
    /// available at this type scale.
    static let height: CGFloat = 284

    /// What the column inside a cell actually has to fit into.
    static var contentHeight: CGFloat { height - verticalPadding * 2 }

    /// The one inset the app adds to the television's own. A focused card
    /// scales up and paints outside its frame; without this the scroll view
    /// clips the near edge of the outermost column.
    static let pageInset: CGFloat = 20

    /// Both edges of the scrolling column, which are fades rather than cuts.
    /// A television app that slices a row of cards in half against an
    /// invisible line looks broken; Apple TV apps dissolve their content into
    /// the edge instead.
    ///
    /// The column's insets are set so that at rest nothing is under either
    /// fade: the section label begins where the top fade has finished, and the
    /// last row ends above the bottom one. A fade is only ever seen by content
    /// moving through it.
    static let edgeFade: CGFloat = 56

    /// The television's title-safe area vertically, which tvOS applies for us
    /// and which the scrolling column deliberately ignores at the bottom.
    ///
    /// Respecting it there put a hard cut 60 points above the physical edge:
    /// a scrolling card stopped dead against an invisible line with an empty
    /// band beneath it, which is the one place on this screen that looked
    /// unfinished. The column now runs to the glass and pays the inset back as
    /// bottom padding instead, so the resting layout is unchanged and only
    /// scrolled content crosses into it.
    static let titleSafeVertical: CGFloat = 60

    /// The television's title-safe area, which tvOS applies for us. Named here
    /// only so the width below can be derived rather than measured.
    static let titleSafeHorizontal: CGFloat = 80

    /// One cell's width on a 1920-point screen, and the content width inside
    /// it. Derived the way the view lays out rather than measured off a
    /// capture, so it stays true when a padding changes: the screen less the
    /// safe area and `pageInset` on each side leaves 1720 points for three
    /// columns and the two 40-point gaps between them.
    static let gridSpacing: CGFloat = 40
    static func width(columns: Int, in screenWidth: CGFloat = 1920) -> CGFloat {
        let available = screenWidth - (titleSafeHorizontal + pageInset) * 2
        return (available - gridSpacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    static func contentWidth(columns: Int, in screenWidth: CGFloat = 1920) -> CGFloat {
        width(columns: columns, in: screenWidth) - horizontalPadding * 2
    }
    /// The most a row may grow into spare screen. `height` is a floor — what
    /// the tallest card needs — and a dashboard with fewer rows than the
    /// screen holds spends the difference rather than leaving a band of dead
    /// background under the last row. The ceiling is what stops one row of
    /// three cards from becoming three very strange ones: about a third again,
    /// the same allowance `ListRowFill.maxSlotUnits` makes for the same reason.
    static let maxHeight: CGFloat = 380

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
        // No page padding of its own. tvOS already insets everything by the
        // title-safe area — 80 points horizontally, 60 vertically — and the
        // 80 and 48 that used to be here were spent *again* on top of it, so a
        // 1920-point screen showed 1560 points of dashboard between 180-point
        // margins. The scrolling column below keeps a small inset, which is
        // not decoration: a focused card scales up and draws about 20 points
        // outside its own frame, and the scroll view would clip that.
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
        }
        // and otherwise nothing. The other branches each say something a
        // viewer cannot get anywhere else — that a sync failed, that one has
        // not finished, or how long ago the last one was, which on a
        // television left running on a wall is the difference between a
        // dashboard with nothing new to say and one that stopped talking.
        // "Your agent widgets" said none of that; it was a caption under a
        // title that already reads "Dashboard".
    }

    @ViewBuilder
    private var content: some View {
        if env.cards.isEmpty && env.liveActivities.isEmpty && !env.hasCompletedInitialSync {
            initialLoadingState
        } else if env.cards.isEmpty && env.liveActivities.isEmpty {
            emptyState
        } else {
            // The viewport height, so a dashboard with fewer rows than the
            // screen holds can spend the difference rather than leaving a
            // band of background under the last row. See `rowHeight(in:)`.
            GeometryReader { proxy in
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
                                fills: env.liveActivities.isEmpty,
                                open: { selectedDetail = .card(card) }
                            )
                        }
                    }
                }
                // Room for a focused card's scale-up, and nothing more.
                .padding(.horizontal, TVCardMetrics.pageInset)
                .padding(.top, TVCardMetrics.edgeFade)
                // The safe area the column below is ignoring, paid back so the
                // last row rests exactly where it did before.
                .padding(.bottom, TVCardMetrics.pageInset + TVCardMetrics.titleSafeVertical)
                // At least a screenful, so a dashboard with fewer rows than
                // the screen holds has slack to give its cards rather than
                // leaving a band of dead background under the last row. A
                // minimum, so a grid that genuinely overflows still scrolls.
                //
                // Only when the grid is the whole page. With a Live Activity
                // above it there are two sections competing for the slack and
                // the taller one takes most of it, which pushed the widget row
                // off the bottom of the insights capture — a screen that was
                // already full has nothing to redistribute anyway.
                .frame(
                    minHeight: env.liveActivities.isEmpty ? proxy.size.height : nil,
                    alignment: .top
                )
            }
            // Render-only, so it costs the focus engine nothing: a masked
            // view is still hit-testable and still focusable, which is what
            // makes this safe on a screen navigated by moving focus rather
            // than by pointing at it.
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: TVCardMetrics.edgeFade)
                    Color.black
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: TVCardMetrics.edgeFade)
                }
            }
            }
            // Down to the glass, and on the reader rather than the scroll view
            // so `proxy.size.height` reports the taller box. Applied inside,
            // the column drew past the safe area while the fill still divided
            // the old height, and every row lost half the inset paid back
            // below. Everything else on screen keeps the title-safe area.
            .ignoresSafeArea(.container, edges: .bottom)
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
                        // Only where the header has no room for it. See the
                        // note beside the header's copy.
                        if dynamicTypeSize.usesTVLargeTextLayout { freshness }
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
                // A title is the card's own name and yields last; the line
                // beside it is metadata and can truncate.
                .layoutPriority(1)
            // Beside the title rather than under it. This card is full width
            // by design — it is one row of a grid the widgets get three of —
            // so its title line has most of a screen of empty space in it,
            // while a line of its own cost a row out of a card that needs the
            // room for its items. Smaller too: when the last update arrived is
            // the card's least urgent fact right up until it stops arriving,
            // and `FreshnessLine` turns itself orange behind a warning glyph
            // when that happens, so the size is not carrying the signal.
            if !dynamicTypeSize.usesTVLargeTextLayout {
                freshness
            }
            Spacer(minLength: 8)
            Text(activity.needsUserAttention ? "Needs you" : activity.state.capitalized)
                .font(.callout.weight(.semibold))
                .tvReadableText(largeTextLineLimit: 2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(activity.tint.opacity(0.18)))
                .foregroundStyle(activity.tint)
                .fixedSize()
        }
    }

    private var freshness: some View {
        TVFreshness(
            updatedAt: activity.updatedAt,
            isStale: { activity.isStale },
            font: dynamicTypeSize.usesTVLargeTextLayout ? .callout : .caption
        )
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
                    .font(TVTypography.rowIcon)
                    .foregroundStyle(item.tint())
                    .frame(width: TVTypography.rowIconColumn)
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

/// The grid cell: a button, and the fixed box its content is drawn in.
///
/// The content is `TVDashboardCardContent` rather than an inline `VStack`
/// because of what the fixed `.frame(height:)` below does to a measurement.
/// Applied here it *is* the answer to "how tall is this card" — 252, always,
/// whether or not the column inside needed more. Ask the content instead and
/// you get the height it actually wanted, which is the only number an
/// overflow shows up in. `TVCardFitTests` asks the content.
struct TVDashboardCardView: View {
    let card: DashboardCard
    /// Whether this card's grid is filling the screen, and may therefore grow
    /// past the height its content needs.
    var fills: Bool = false
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var textScale: TVTextScale { TVTextScale(dynamicTypeSize) }

    /// The floor a card is measured against — what its content needs.
    private var cardHeight: CGFloat? { textScale.cardHeight }

    var body: some View {
        Button(action: open) {
            TVDashboardCardContent(card: card)
                // Top alignment is the box's business, not the column's. It
                // used to be a `Spacer` inside the column, which is
                // indistinguishable from content to anything measuring it.
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, TVCardMetrics.horizontalPadding)
                .padding(.vertical, TVCardMetrics.verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A range only where the grid has slack to hand out. The
                // floor is what the tallest card needs and is what
                // `TVCardFitTests` asserts against; the ceiling stops one row
                // of three cards growing to the height of the screen. Where
                // nothing is filling, the height stays exact — a frame that is
                // merely *allowed* to grow resolves its ideal ambiguously, and
                // cards grew on a screen that had nothing spare.
                .frame(
                    minHeight: cardHeight ?? textScale.cardMinimumHeight,
                    maxHeight: fills ? TVCardMetrics.maxHeight : cardHeight
                )
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

    /// The label says what is on screen: `listContent` draws
    /// `TVDashboardCardContent.listRowLimit(for:)` rows and `StatusStripView`
    /// fourteen pips. Pressing Select opens the panel, which has the rest —
    /// so this deliberately does not read out what the cell chose to defer.
    private var accessibilitySummary: String {
        let detail = CardAccessibilitySummary.detail(
            for: card,
            rowLimit: card.template == .history
                ? 14
                : TVDashboardCardContent.listRowLimit(for: card)
        )
        return detail.isEmpty
            ? CardAccessibilitySummary.summary(for: card)
            : CardAccessibilitySummary.summary(for: card) + " " + detail
    }
}

/// The column a cell draws, separated from the box it is drawn in so that its
/// natural height can be measured. See `TVDashboardCardView`.
struct TVDashboardCardContent: View {
    let card: DashboardCard
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// What a cell holds, which is less than a card has.
    ///
    /// The cell is a *medium widget* — 493x252, against an iOS medium's
    /// 364x170 — and tvOS type is about twice iOS type while the box is only
    /// 1.35x wider. So it holds roughly four lines, and a card routinely has
    /// six or seven. Everything omitted here is on `TVDetailView`, which one
    /// press of Select away has the whole subtitle, the whole briefing, every
    /// row and the deadline; nothing below is *lost*, it is deferred.
    ///
    /// The rule is: identity, then the headline, then at most two supporting
    /// things, and the subtitle yields first — it is the line most likely to
    /// restate the value or the producer, and every template that drops it has
    /// something more specific in its place.
    var body: some View {
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
                        .tvReadableText(standardLineLimit: 1, largeTextLineLimit: 3)
                }
            case .summary, .action:
                valueContent
            }

        }
    }

    /// A measured row, and the header above it with and without the
    /// attribution line under the title. Both are what the probe reports at
    /// standard type; re-measure if either changes.
    private static let listRowHeight: CGFloat = 46
    private static let listRowSpacing: CGFloat = 8
    private static let headerHeight: CGFloat = 58
    private static let headerHeightWithProducer: CGFloat = 91

    /// How many rows a `list` cell draws — taken from the room, not chosen.
    ///
    /// A constant is a guess about a canvas whose height depends on what else
    /// the card drew, and this guess was wrong in both directions: three rows
    /// overflowed a cell carrying an attribution line, and two left a third of
    /// a card blank when it was not. Same arithmetic a widget's list uses, for
    /// the same reason — see `ListRowFill`, including why a constant survives
    /// only as a ceiling.
    static func listRowLimit(for card: DashboardCard) -> Int {
        let header = showsProducer(card) ? headerHeightWithProducer : headerHeight
        let available = TVCardMetrics.contentHeight - header - 14
        return min(
            6,
            ListRowFill.capacity(
                height: available + listRowSpacing,
                unit: listRowHeight + listRowSpacing
            )
        )
    }

    /// Whether the header carries the attribution under the title.
    ///
    /// A `list` card never draws its subtitle — its column is rows — so its
    /// header is the only place its producer can appear, and the attribution
    /// is kept whatever the subtitle says. `drawsCardSubtitle` is shared with
    /// the iOS renderer, which lays a card out the same way.
    static func showsProducer(_ card: DashboardCard) -> Bool {
        guard card.producer != nil else { return false }
        return !(card.template.drawsCardSubtitle && card.producerRepeatsSubtitle)
    }

    private var producerLine: CardProducer? {
        Self.showsProducer(card) ? card.producer : nil
    }

    /// Internal rather than private so `TVCardFitTests` can ask what width
    /// it wants: the header is the row that runs out of horizontal room.
    var header: some View {
        // 18 rather than 12. The gap was set when the glyph was `.title2` and
        // 71 points wide; at `.headline` it is 48, and the same 12 points read
        // tight against the title because the symbol's own bounding box came
        // in with it.
        HStack(spacing: 18) {
            if let icon = card.icon {
                Image(systemName: icon)
                    .font(TVTypography.cardIcon)
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
                if let producer = producerLine {
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
            trailingBadge
                // The row has four things in it and only ever had one rule for
                // dividing the width: none. An `HStack` whose children want
                // more than it has shrinks *every* flexible one, so a header a
                // little too wide truncated the title, the attribution and the
                // badge all at once — the badge read "Needs y…", which is the
                // one string on the card that had to survive. Sizing the badge
                // first and letting the title column take what is left states
                // which of them yields.
                .layoutPriority(1)
                .fixedSize()
        }
    }

    /// The same two slots iOS draws — a semantic status glyph, then the
    /// attention or status badge — kept as two so the platforms stay
    /// symmetric.
    private var trailingBadge: some View {
        HStack(spacing: 8) {
            if let statusIcon = card.statusIcon {
                Image(systemName: statusIcon)
                    .font(.headline)
                    .foregroundStyle(card.status.tint)
            }
            if card.needsUserAttention {
                // The shared badge rather than the look-alike capsule this
                // used to hand-roll. Its compact form is a glyph, which is
                // what the slot beside a title has room for; the words are on
                // the detail panel the card opens, and VoiceOver reads
                // "Needs your attention" from the badge either way.
                AttentionBadge(compact: true, font: .headline)
            } else {
                StatusBadge(status: card.status, compact: true)
            }
        }
    }

    /// The headline, with the countdown beside it rather than under it.
    ///
    /// A deadline on its own row cost a row — 37 points plus the 14 above it,
    /// which is a fifth of everything a cell has — to say something six
    /// characters long. Beside the value it is free, and it reads better: the
    /// number and the time it is measured against belong together. The Live
    /// Activity card above already puts its own "~8 min" on a shared row.
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
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
            if let deadline = card.deadline {
                Spacer(minLength: 8)
                Label {
                    Text(deadline, style: .relative)
                } icon: {
                    Image(systemName: "clock")
                }
                // `.caption` is 25pt here. A countdown someone is meant to
                // read across a room is not caption material.
                .font(.body)
                .foregroundStyle(.secondary)
                .tvReadableText()
                .layoutPriority(1)
                .fixedSize()
            }
        }
    }

    private var valueContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            headline
            if let subtitle = card.subtitle, card.template != .briefing {
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

    /// Headline and one supporting line above a plot — a sparkline for
    /// `chart`, status pips for `history`, a segmented bar for `breakdown`.
    /// The headline is the shared one, so a plot card's number is the same
    /// size as any other card's; the supporting line is what steps down,
    /// preserving hierarchy without sacrificing the plot.
    @ViewBuilder
    private var chartContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            headline
            // A plot card spends its supporting row on the comparison rather
            // than the subtitle. The comparison is the same statement made
            // precisely — "+18 vs Monday" against "up 18 this week" — and the
            // plot behind it is the trend the subtitle was describing, so the
            // subtitle is the one line here that says nothing the card is not
            // already showing. It is on the panel.
            if let subtitle = card.subtitle, card.comparison == nil {
                Text(subtitle)
                    .tvScaledSystemFont(
                        size: TVTypography.chartSubtitleSize,
                        // Use the headline's scaling curve, which is now the
                        // shared one. On tvOS, mixing curves makes a nominal
                        // 26pt caption physically taller than the nominal 34pt
                        // value at the standard setting.
                        relativeTo: .title
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
                ForEach(items.prefix(Self.listRowLimit(for: card))) { item in
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
