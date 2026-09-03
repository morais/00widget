import CoreImage.CIFilterBuiltins
import SwiftUI

/// What the dashboard has opened a detail panel for.
///
/// It carries the value the viewer selected, and `TVDetailView` re-reads that
/// value from the environment on every refresh. A television is left running
/// on a wall, so a panel somebody walked away from has to keep up with the
/// dashboard behind it rather than freeze at the moment it was opened.
enum TVDetailSubject: Identifiable {
    case card(DashboardCard)
    case activity(LiveActivitySession)

    var id: String {
        switch self {
        case .card(let card): "card|\(card.id)"
        case .activity(let activity): "activity|\(activity.id)"
        }
    }

    var title: String {
        switch self {
        case .card(let card): card.title
        case .activity(let activity): activity.title
        }
    }

    var deepLink: URL? {
        switch self {
        case .card(let card): card.deepLink
        case .activity(let activity): activity.deepLink
        }
    }

    /// Everything the panel draws in colour: the icon, the plot, the progress
    /// bar, the badge. A card takes it from its status, an activity from its
    /// kind or its current semantic signal, which is what both surfaces do.
    var tint: Color {
        switch self {
        case .card(let card): card.status.tint
        case .activity(let activity): activity.tint
        }
    }

    var updatedAt: Date {
        switch self {
        case .card(let card): card.updatedAt
        case .activity(let activity): activity.updatedAt
        }
    }

    var isStale: Bool {
        switch self {
        case .card(let card): card.isStale
        case .activity(let activity): activity.isStale
        }
    }
}

/// The larger reading of one card or one Live Activity.
///
/// The dashboard grid draws a card at a size that fits nine of them on screen;
/// this draws one, so it has room for the whole list rather than three rows, the
/// whole history rather than the last fourteen pips, and a plot tall enough to
/// have a shape. It is also where the two things a dashboard card must not
/// offer now live: the buttons that run an action, and the QR code for the
/// card's link.
///
/// Presented by `TVDashboardView`, which nothing tears down while it is up —
/// unlike Settings, which has to be presented by the root because signing out
/// replaces the dashboard. See the note in `TVRootView`.
struct TVDetailView: View {
    @EnvironmentObject var env: TVEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let subject: TVDetailSubject

    @State private var pendingAction: ActionDefinition?
    @State private var runningActionID: String?
    @State private var actionError: String?

    /// The freshest version of what the viewer opened. A panel is a view onto
    /// the dashboard's data, not a copy of it: the auto-refresh that updates
    /// the grid behind has to update this too, or a countdown stops counting
    /// and a value quietly goes an hour stale while filling the screen.
    private var resolved: TVDetailSubject {
        switch subject {
        case .card(let card):
            .card(env.cards.first { $0.id == card.id } ?? card)
        case .activity(let activity):
            .activity(env.liveActivities.first { $0.id == activity.id } ?? activity)
        }
    }

    var body: some View {
        let subject = resolved
        ZStack {
            Color(red: 0.025, green: 0.03, blue: 0.05)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.clear, subject.tint.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 36) {
                header(for: subject)

                HStack(alignment: .top, spacing: 64) {
                    content(for: subject)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    if let url = subject.deepLink {
                        TVQRPanel(url: url)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                footer(for: subject)
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 56)
        }
        .confirmationDialog(
            "Run action?",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button(action.label, role: action.role == .destructive ? .destructive : nil) {
                run(action)
                pendingAction = nil
            }
        } message: { action in
            Text("Run \(action.label) for \(subject.title)?")
        }
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "Please try again.")
        }
    }

    // MARK: - Chrome

    private func header(for subject: TVDetailSubject) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    if let icon = iconName(for: subject) {
                        Image(systemName: icon)
                            .tvScaledSystemFont(size: 44, relativeTo: .largeTitle)
                            .foregroundStyle(subject.tint)
                            .accessibilityHidden(true)
                    }
                    Text(subject.title)
                        .font(.largeTitle.weight(.bold))
                        .tvReadableText(
                            standardLineLimit: 1,
                            largeTextLineLimit: 2,
                            standardMinimumScaleFactor: 0.7
                        )
                        .accessibilityAddTraits(.isHeader)
                    statusChip(for: subject)
                }
                if case .card(let card) = subject, let producer = card.producer {
                    HStack(spacing: 8) {
                        if let icon = producer.icon {
                            Image(systemName: icon).accessibilityHidden(true)
                        }
                        Text(producer.label)
                    }
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .tvReadableText(standardLineLimit: 1, largeTextLineLimit: 2)
                }
                freshness(for: subject)
            }

            Spacer(minLength: 24)

            Button("Close", systemImage: "chevron.backward") {
                dismiss()
            }
        }
        // The one focusable thing up here, and on a card with no actions the
        // one focusable thing on the screen. A focus section is considered by
        // direction rather than by alignment, which is what lets focus come
        // back up to it from the buttons below.
        .focusSection()
    }

    @ViewBuilder
    private func statusChip(for subject: TVDetailSubject) -> some View {
        switch subject {
        case .card(let card):
            HStack(spacing: 10) {
                if let statusIcon = card.statusIcon {
                    Image(systemName: statusIcon)
                        .font(.title3)
                        .foregroundStyle(card.status.tint)
                        .accessibilityHidden(true)
                }
                Text(card.status.label)
            }
            .modifier(TVChip(tint: card.status.tint))
            .accessibilityLabel("Status")
            .accessibilityValue(card.status.label)
        case .activity(let activity):
            HStack(spacing: 10) {
                if let statusIcon = activity.semanticStatusIcon {
                    Image(systemName: statusIcon)
                        .font(.title3)
                        .foregroundStyle(activity.tint)
                        .accessibilityHidden(true)
                }
                Text(activity.state.capitalized)
            }
            .modifier(TVChip(tint: activity.tint))
        }
    }

    private func freshness(for subject: TVDetailSubject) -> some View {
        TVFreshness(updatedAt: subject.updatedAt, isStale: { subject.isStale }, font: .title3)
    }

    @ViewBuilder
    private func footer(for subject: TVDetailSubject) -> some View {
        if case .card(let card) = subject, let actions = card.actions, !actions.isEmpty {
            let actionsLayout = dynamicTypeSize.usesTVLargeTextLayout
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                : AnyLayout(HStackLayout(spacing: 24))
            actionsLayout {
                ForEach(actions) { action in
                    let isRunning = runningActionID == action.id
                    Button {
                        request(action, for: card)
                    } label: {
                        HStack(spacing: 12) {
                            // Beside the label, never instead of it: a
                            // `ProgressView` alone has nothing to read, so a
                            // running button announced nothing at all.
                            if isRunning { ProgressView() }
                            Label(
                                action.label,
                                systemImage: action.role == .destructive
                                    ? "exclamationmark.triangle.fill"
                                    : "bolt.fill"
                            )
                        }
                    }
                    .disabled(runningActionID != nil)
                    .accessibilityValue(isRunning ? "In progress" : "")
                }
                Spacer(minLength: 0)
            }
            .focusSection()
        }
    }

    // MARK: - Subject content

    @ViewBuilder
    private func content(for subject: TVDetailSubject) -> some View {
        switch subject {
        case .card(let card): TVCardDetailContent(card: card)
        case .activity(let activity): TVActivityDetailContent(activity: activity)
        }
    }

    private func iconName(for subject: TVDetailSubject) -> String? {
        switch subject {
        case .card(let card): card.icon
        case .activity(let activity): activity.detailIconName
        }
    }

    // MARK: - Actions

    private func request(_ action: ActionDefinition, for card: DashboardCard) {
        if action.confirm || action.role == .destructive {
            pendingAction = action
        } else {
            run(action)
        }
    }

    private func run(_ action: ActionDefinition) {
        guard case .card(let card) = resolved else { return }
        runningActionID = action.id
        actionError = nil

        Task {
            defer { runningActionID = nil }
            let requiresConfirmation = action.confirm || action.role == .destructive
            guard let client = requiresConfirmation ? env.confirmedActionClient() : env.apiClient() else {
                let message = "The server connection is unavailable."
                actionError = message
                AccessibilityAnnouncement.post(message)
                return
            }
            do {
                if requiresConfirmation {
                    try await client.runConfirmedAction(id: action.id, cardId: card.id)
                } else {
                    try await client.runAction(id: action.id, cardId: card.id)
                }
                await env.fetchCards()
                // Success used to be entirely silent: the only evidence was a
                // refetch that may change nothing visible on a screen nobody is
                // standing in front of.
                AccessibilityAnnouncement.post("\(action.label) finished for \(card.title).")
            } catch {
                actionError = error.localizedDescription
                // The alert takes focus and reads itself, so this says only
                // what the alert's title cannot: which action failed.
                AccessibilityAnnouncement.post("\(action.label) failed for \(card.title).")
            }
        }
    }
}

// MARK: - Card

private struct TVCardDetailContent: View {
    let card: DashboardCard
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// What the grid cell had no room for. The dashboard draws three list rows
    /// and fourteen history pips because nine cards share the screen; one card
    /// alone can show many more.
    ///
    /// The counts are bounded rather than scrolled, and they are the tuned
    /// numbers rather than round ones. tvOS scrolls by moving focus and nothing
    /// in this column is focusable, so a row past the bottom of the screen is
    /// not below the fold — it is unreachable, and the panel does not even
    /// clip it honestly: an over-tall `VStack` is centred in the space it was
    /// given, which cut the *header* off the top of a `history` card as well as
    /// the last rows off the bottom. What fits is the 1080-line screen less
    /// this panel's chrome and headline, divided by an 94-point row.
    /// Enlarged type does not make the screen taller, so every one of these
    /// counts is the standard-size figure divided by how much bigger the rows
    /// have become — see `TVTextScale.rowLimit(standard:)`. Before that they
    /// were constants, which meant an accessibility size drew six rows into
    /// the room for three and lost the last of them off a panel that cannot
    /// scroll.
    private var listRowLimit: Int { rowLimit(standard: 6) }
    private var breakdownRowLimit: Int { rowLimit(standard: 5) }
    private var briefingSectionLimit: Int { rowLimit(standard: 6) }

    /// The budget above is the room a panel has for rows when a headline is
    /// the only other thing in it. Two blocks are optional and neither is in
    /// that figure: the deadline line this view draws under the rows, and the
    /// panel's footer of action buttons. Each costs about a row — and at
    /// accessibility sizes the footer stacks its buttons, so it costs one for
    /// each of them. A card carrying both used to draw its full six rows into
    /// the room for four, and a panel that overruns is centred rather than
    /// clipped: the header goes off the top and the buttons off the bottom, on
    /// a column nothing can scroll. Verified against exactly that card.
    private func rowLimit(standard: Int) -> Int {
        var chrome = card.deadline != nil ? 1 : 0
        let actions = card.actions?.count ?? 0
        if actions > 0 {
            chrome += textScale == .accessibility ? actions : 1
        }
        // The same floor `TVTextScale` applies, and for its reason: one row is
        // a list that has stopped being one. A panel promised more than the
        // screen holds can only pick which way to be wrong.
        return Swift.max(2, textScale.rowLimit(standard: standard) - chrome)
    }
    /// The strip is a fixed 44 points however large the type is, and its pips
    /// share the width rather than stacking, so this one does not scale.
    private let historyPipLimit = 24

    private var textScale: TVTextScale { TVTextScale(dynamicTypeSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            headline

            switch card.template {
            case .summary, .action:
                EmptyView()
            case .progress:
                progress
            case .list:
                rows(Array((card.items ?? []).prefix(listRowLimit)), ranked: true)
            case .chart:
                chart
            case .history:
                history
            case .breakdown:
                breakdown
            case .briefing:
                briefing
            }

            if let deadline = card.deadline {
                Label {
                    HStack(spacing: 8) {
                        Text(deadline, style: .relative)
                        Text("remaining")
                    }
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.title2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 10) {
            if card.value != nil || card.unit != nil {
                Text("\(card.value ?? "—")\(card.unit.map { " \($0)" } ?? "")")
                    .tvScaledSystemFont(
                        size: TVDetailTypography.headline,
                        relativeTo: .largeTitle,
                        weight: .semibold,
                        design: .rounded
                    )
                    .tvReadableText(
                        standardLineLimit: 1,
                        largeTextLineLimit: 2,
                        standardMinimumScaleFactor: TVTypography.scale(
                            0.5,
                            for: TVDetailTypography.headline
                        )
                    )
            }
            if let comparison = card.comparison {
                HStack(spacing: 8) {
                    Image(systemName: comparison.signal.symbolName).accessibilityHidden(true)
                    Text(comparison.value).fontWeight(.semibold)
                    Text(comparison.label).foregroundStyle(.secondary)
                }
                .font(.title3)
                .foregroundStyle(comparison.signal.tint)
                .tvReadableText(standardLineLimit: 1, largeTextLineLimit: 2)
            }
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    // Bounded like every other line on this screen. The row
                    // counts below are a budget computed against a headline of
                    // a known height, and the subtitle was the one part of it
                    // a producer controls: it accepts 240 characters, which
                    // wrap to about two rows' worth of height the budget does
                    // not know it has lost. A panel that overruns is centred
                    // rather than clipped, so the cost is the header off the
                    // top as well as the last rows off the bottom, on a column
                    // nothing can scroll.
                    .tvReadableText(standardLineLimit: 2, largeTextLineLimit: 3)
            }
        }
    }

    private var briefing: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach((card.briefing?.sections ?? []).prefix(briefingSectionLimit)) { section in
                VStack(alignment: .leading, spacing: 4) {
                    if let label = section.label, !label.isEmpty {
                        Text(label)
                            .font(.headline)
                            .foregroundStyle(card.status.tint)
                    }
                    Text(section.text)
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .tvReadableText(standardLineLimit: 3, largeTextLineLimit: 6)
                }
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let value = card.progressValue {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: value)
                    .tint(card.status.tint)
                    .scaleEffect(x: 1, y: 2.5, anchor: .leading)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
                Text("\(Int((value * 100).rounded()))% complete")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if let chart = card.chart, chart.isRenderable {
            // One focus target for the whole plot. Sixty focusable columns
            // would trap remote navigation; left/right changes the shared
            // selection while up/down remains available to the focus engine.
            InspectableChartView(
                chart: chart,
                tint: card.status.tint,
                title: card.title,
                unit: card.unit,
                plotHeight: 230,
                lineWidth: 6
            )
        }
    }

    /// The strip, then the most recent runs as rows, newest first — the strip
    /// says how the last two dozen went and the rows say which ones and when.
    /// A `history` card carrying a chart as well spends the rows' room on it,
    /// because both cannot fit and the plot is the wider statement.
    @ViewBuilder
    private var history: some View {
        let items = card.items ?? []
        let plotted = card.chart.flatMap { $0.isRenderable ? $0 : nil }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                StatusStripView(items: items, limit: historyPipLimit, height: 44)
                rows(
                    Array(
                        items.suffix(rowLimit(standard: plotted == nil ? 4 : 2))
                            .reversed()
                    ),
                    ranked: false
                )
            }
        }
        if let plotted {
            InspectableChartView(
                chart: plotted,
                tint: card.status.tint,
                title: card.title,
                unit: card.unit,
                plotHeight: 130,
                lineWidth: 6,
                compact: true
            )
        }
    }

    @ViewBuilder
    private var breakdown: some View {
        let items = card.items ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                CompositionBarView(items: items, tint: card.status.tint, height: 48)
                // The legend the small card cannot afford. A bar without one
                // says only that the quantity is split; which segment is which
                // is the reason someone opened the panel.
                VStack(spacing: 12) {
                    ForEach(
                        Array(CompositionBarView.shares(of: items).prefix(breakdownRowLimit).enumerated()),
                        id: \.element.item.id
                    ) { index, entry in
                        TVDetailRow(
                            item: entry.item,
                            swatch: CompositionBarView.tint(
                                for: entry.item,
                                index: index,
                                base: card.status.tint,
                                increasedContrast: colorSchemeContrast == .increased
                            ),
                            swatchIndex: index,
                            fraction: nil,
                            tint: card.status.tint,
                            share: entry.share
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ items: [DashboardItem], ranked: Bool) -> some View {
        if items.isEmpty {
            Text("No items")
                .font(.title2)
                .foregroundStyle(.secondary)
        } else {
            let fractions = ranked ? RankedRows.fractions(for: items) : nil
            VStack(spacing: 12) {
                ForEach(items) { item in
                    TVDetailRow(
                        item: item,
                        swatch: nil,
                        swatchIndex: 0,
                        fraction: fractions?[item.id],
                        tint: card.status.tint,
                        share: nil
                    )
                }
            }
        }
    }
}

/// One item, at the size a screen showing a single card can give it.
private struct TVDetailRow: View {
    let item: DashboardItem
    /// The colour of this row's segment in a `breakdown` bar, drawn as a
    /// swatch so the legend and the bar can be matched up.
    let swatch: Color?
    /// Which segment, so the swatch can carry the same marker the bar's
    /// segment is textured with when colour is not being read.
    let swatchIndex: Int
    let fraction: Double?
    let tint: Color
    let share: Double?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let rowLayout = dynamicTypeSize.usesTVLargeTextLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 16))
        rowLayout {
            label
            Spacer(minLength: 16)
            trailingValue
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(alignment: .leading) {
            if let fraction {
                RankedRowBar(fraction: fraction, tint: RankedRows.tint(for: item, base: tint))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            }
        }
    }

    private var increasedContrast: Bool { colorSchemeContrast == .increased }

    private var label: some View {
        HStack(alignment: .top, spacing: 16) {
            if let swatch {
                if differentiateWithoutColor {
                    SeriesSwatch(
                        index: swatchIndex,
                        color: swatch,
                        size: 24,
                        differentiateWithoutColor: true
                    )
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(swatch)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    SemanticFlowIcon(item.semantic, font: .body)
                    Text(item.title)
                        .font(.title3)
                        .tvReadableText(largeTextLineLimit: 2)
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .tvReadableText(largeTextLineLimit: 3)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingValue: some View {
        HStack(spacing: 16) {
            if let share {
                Text("\(Int((share * 100).rounded()))%")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let value = item.displayValue {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(
                        item.status.map {
                            VisualAccommodations.textTint($0.tint, increasedContrast: increasedContrast)
                        } ?? AnyShapeStyle(.primary)
                    )
                    .tvReadableText()
            } else if let status = item.status {
                Text(status.label)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(
                        VisualAccommodations.textTint(status.tint, increasedContrast: increasedContrast)
                    )
                    .tvReadableText()
            }
        }
    }
}

// MARK: - Live Activity

private struct TVActivityDetailContent: View {
    let activity: LiveActivitySession

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            headline

            if !presentationItems.isEmpty {
                VStack(spacing: 12) {
                    ForEach(presentationItems) { item in
                        TVLiveActivityItemRow(item: item)
                    }
                }
            }

            if let chart = activity.chart, chart.isRenderable {
                InspectableChartView(
                    chart: chart,
                    tint: activity.tint,
                    title: activity.title,
                    unit: activity.unit,
                    plotHeight: presentationItems.isEmpty ? 230 : 120,
                    lineWidth: 6,
                    compact: !presentationItems.isEmpty
                )
            } else if let progress = activity.progress, activity.endsAt == nil {
                ProgressView(value: max(0, min(progress, 1)))
                    .tint(activity.tint)
                    .scaleEffect(x: 1, y: 2.5, anchor: .leading)
                    .padding(.vertical, 8)
            }

            Spacer(minLength: 0)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let endsAt = activity.endsAt {
                LiveActivityCountdownText(
                    endsAt: endsAt,
                    granularity: activity.countdownGranularity
                )
                .tvScaledSystemFont(
                    size: TVDetailTypography.headline,
                    relativeTo: .largeTitle,
                    weight: .semibold,
                    design: .rounded
                )
                .monospacedDigit()
                .tvReadableText(
                    standardLineLimit: 1,
                    largeTextLineLimit: 2,
                    standardMinimumScaleFactor: TVTypography.scale(
                        0.5,
                        for: TVDetailTypography.headline
                    )
                )
            } else if activity.value != nil || activity.unit != nil {
                Text("\(activity.value ?? "—")\(activity.unit.map { " \($0)" } ?? "")")
                    .tvScaledSystemFont(
                        size: TVDetailTypography.headline,
                        relativeTo: .largeTitle,
                        weight: .semibold,
                        design: .rounded
                    )
                    .tvReadableText(
                        standardLineLimit: 1,
                        largeTextLineLimit: 2,
                        standardMinimumScaleFactor: TVTypography.scale(
                            0.5,
                            for: TVDetailTypography.headline
                        )
                    )
            }
            if let subtitle = activity.subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    // Bounded for the reason the card panel's is.
                    .tvReadableText(standardLineLimit: 2, largeTextLineLimit: 3)
            }
        }
    }

    private var presentationItems: [LiveActivityItem] {
        activity.budgetedPresentationItems(fillingTo: 3)
    }
}

// MARK: - QR

/// The card's link, as the only thing a television can usefully do with one.
///
/// The URL itself is not drawn. Nobody types a URL off a television, the panel
/// wants the room for the card's own data, and a long link wraps to four lines
/// of monospace that says nothing the QR code does not. It stays in the
/// accessibility label, where it is the one way to hear where the code goes.
struct TVQRPanel: View {
    let url: URL

    var body: some View {
        VStack(spacing: 20) {
            if let image = TVQRCode.image(for: url.absoluteString) {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(28)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .frame(width: 360, height: 360)
                    .accessibilityLabel("QR code for \(url.absoluteString)")
            } else {
                ContentUnavailableView(
                    "Couldn’t create QR code",
                    systemImage: "qrcode",
                    description: Text(url.absoluteString)
                )
                .frame(width: 360, height: 360)
            }

            // Icon above rather than beside: an inline `Label` leaves the text
            // about 300 points wide inside this column, which wraps "Scan to
            // open on your phone" onto three ragged lines.
            VStack(spacing: 10) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .tvScaledSystemFont(size: 40, relativeTo: .title3)
                    .accessibilityHidden(true)
                Text("Scan to open on your phone")
                    .multilineTextAlignment(.center)
            }
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .frame(width: 360)
    }
}

private enum TVQRCode {
    static func image(for value: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"

        let context = CIContext()
        guard
            let output = filter.outputImage,
            let cgImage = context.createCGImage(output, from: output.extent)
        else {
            return nil
        }
        return Image(decorative: cgImage, scale: 1)
    }
}

// MARK: - Shared bits

private enum TVDetailTypography {
    /// One card fills the screen here, so the headline is more than twice the
    /// grid cell's 44pt. `TVTypography.floor` still governs how far
    /// `minimumScaleFactor` may shrink it.
    static let headline: CGFloat = 96
}

private struct TVChip: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().fill(tint.opacity(0.18)))
    }
}

extension LiveActivitySession {
    /// The icon the producer sent, or the one its kind implies. Shared by the
    /// dashboard card and the detail panel so the same activity cannot be
    /// drawn with two different glyphs on the two screens.
    var detailIconName: String {
        if let icon { return icon }
        switch kind {
        case .generic: return "square.dashed"
        case .progress: return "chart.bar"
        case .charging: return "bolt.car"
        case .appliance: return "washer"
        case .job: return "hammer"
        case .timer: return "timer"
        }
    }
}
