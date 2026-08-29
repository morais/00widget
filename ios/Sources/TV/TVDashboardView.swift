import SwiftUI

struct TVDashboardView: View {
    @EnvironmentObject var env: TVEnvironment
    /// Owned by `TVRootView`, which presents the cover: see the note there.
    @Binding var showingSettings: Bool
    @State private var selectedLink: TVWebLink?
    @State private var pendingAction: TVPendingAction?
    @State private var runningAction: TVRunningAction?
    @State private var actionError: String?
    @FocusState private var settingsFocused: Bool

    private let widgetColumnCount = 3

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
        .fullScreenCover(item: $selectedLink) { link in
            TVWebLinkView(link: link)
        }
        .confirmationDialog(
            "Run action?",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { pending in
            Button(
                pending.action.label,
                role: pending.action.role == .destructive ? .destructive : nil
            ) {
                run(pending.action, for: pending.card)
                pendingAction = nil
            }
        } message: { pending in
            Text("Run \(pending.action.label) for \(pending.card.title)?")
        }
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                actionError = nil
            }
        } message: {
            Text(actionError ?? "Please try again.")
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
            .focused($settingsFocused)
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let error = env.lastSyncError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if let lastSyncAt = env.lastSyncAt {
            Text("Updated \(lastSyncAt.formatted(.relative(presentation: .named)))")
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
        if env.cards.isEmpty && env.liveActivities.isEmpty {
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
                                openLink: { openLink(for: activity) },
                                focusSettings: { settingsFocused = true }
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
                                runningAction: runningAction,
                                openLink: { openLink(for: card) },
                                runAction: { request($0, for: card) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
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

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.dashed")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("Nothing to show yet")
                .font(.title)
            Text("Publish a widget or start a Live Activity from your agent.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openLink(for card: DashboardCard) {
        guard let url = card.deepLink else { return }
        selectedLink = TVWebLink(cardTitle: card.title, url: url)
    }

    private func openLink(for activity: LiveActivitySession) {
        guard let url = activity.deepLink else { return }
        selectedLink = TVWebLink(cardTitle: activity.title, url: url)
    }

    private func request(_ action: ActionDefinition, for card: DashboardCard) {
        if action.confirm || action.role == .destructive {
            pendingAction = TVPendingAction(card: card, action: action)
        } else {
            run(action, for: card)
        }
    }

    private func run(_ action: ActionDefinition, for card: DashboardCard) {
        runningAction = TVRunningAction(cardID: card.id, actionID: action.id)
        actionError = nil

        Task {
            defer { runningAction = nil }
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
                // refetch that may change nothing visible on a screen nobody
                // is standing in front of.
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

private struct TVLiveActivityCardView: View {
    let activity: LiveActivitySession
    let openLink: () -> Void
    let focusSettings: () -> Void

    /// Two columns rather than one row per item. Six rows is the published
    /// maximum, so the grid is at most three rows tall, and each row keeps
    /// roughly the proportions the phone card gives it. Stacking them full
    /// width would leave the same empty band across the middle of the card
    /// that drawing no items at all left.
    private let itemColumns = Array(
        repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
        count: 2
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: openLink) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let subtitle = activity.subtitle {
                                Text(subtitle)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            freshness
                        }
                        Spacer(minLength: 12)
                        trailingValue
                    }

                    // A composite activity says what it is doing through its
                    // rows; dropping them left this card showing a title and a
                    // number where the phone showed four.
                    if !activeItems.isEmpty {
                        LazyVGrid(columns: itemColumns, alignment: .leading, spacing: 16) {
                            ForEach(activeItems) { item in
                                TVLiveActivityItemRow(item: item)
                            }
                        }
                    }

                    if let chart = activity.chart, chart.isRenderable {
                        // Taller than the widget card's plot: this one has the
                        // full width of the screen, and a 46-point trace read
                        // as a flat line from a sofa.
                        SparklineView(chart: chart, tint: activity.kind.tint, lineWidth: 4)
                            .frame(height: 72)
                    } else if let progress = activity.progress,
                              activity.endsAt == nil,
                              // Rows replace the progress bar, as they do on
                              // every other surface.
                              activeItems.isEmpty {
                        ProgressView(value: max(0, min(progress, 1)))
                            .tint(activity.kind.tint)
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
                .frame(minHeight: 260)
                .contentShape(RoundedRectangle(cornerRadius: 24))
                // See the note in `TVDashboardCardView`: this has to sit inside
                // the button's label to replace what the button synthesizes.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilitySummary))
            }
            .buttonStyle(.card)
            .onMoveCommand { direction in
                if direction == .up {
                    focusSettings()
                }
            }
            // A card with no link is still the thing focus lands on and the
            // thing VoiceOver reads, so it stays a focusable button — but it
            // must not claim it can be activated, because `openLink` returns
            // immediately when there is no URL. See `TVDashboardCardView`.
            .modifier(TVInertWhenUnlinked(isLinked: activity.deepLink != nil))
            .accessibilityHint(
                activity.deepLink == nil ? "" : "Shows a QR code for the activity link"
            )

            if activity.deepLink != nil {
                Button(action: openLink) {
                    Label("Open link", systemImage: "qrcode")
                }
                .frame(height: 72)
            } else {
                Color.clear.frame(height: 72)
            }
        }
    }

    /// The shared summary, then a line per item. A phone can leave the rows as
    /// their own elements because it scrolls through them; the television draws
    /// the whole card as one focusable unit, so anything left out of this label
    /// is not read anywhere — and on a composite activity the rows *are* the
    /// content.
    private var accessibilitySummary: String {
        ([LiveActivityAccessibilitySummary.summary(for: activity)]
            + activeItems.map(LiveActivityAccessibilitySummary.summary(for:)))
            .joined(separator: ". ")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(activity.kind.tint)
            // What the activity is doing right now, beside what it is.
            if let statusIcon = activity.statusIcon {
                Image(systemName: statusIcon)
                    .font(.headline)
                    .foregroundStyle(activity.kind.tint)
            }
            Text(activity.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            Text(activity.state.capitalized)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(activity.kind.tint.opacity(0.18)))
                .foregroundStyle(activity.kind.tint)
        }
    }

    /// The page header's "Updated" is when this device last synced; this is
    /// when the *producer* last published, which is a different fact and the
    /// one that goes wrong quietly. A television is left running on a wall, so
    /// an activity whose producer stopped an hour ago has to say so rather than
    /// keep presenting its last numbers as current.
    @ViewBuilder
    private var freshness: some View {
        if activity.isStale {
            Label(
                "Not updating · last update \(activity.updatedAt.formatted(.relative(presentation: .named)))",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            .lineLimit(1)
        } else {
            Text("Updated \(activity.updatedAt.formatted(.relative(presentation: .named)))")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var trailingValue: some View {
        if let endsAt = activity.endsAt {
            LiveActivityCountdownText(
                endsAt: endsAt,
                granularity: activity.countdownGranularity
            )
            .font(.system(size: 32, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
        } else if let value = activity.value {
            VStack(alignment: .trailing, spacing: 0) {
                Text(value)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
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
        (activity.items ?? []).filter(\.isActive)
    }

    private var iconName: String {
        if let icon = activity.icon { return icon }
        switch activity.kind {
        case .generic: return "square.dashed"
        case .progress: return "chart.bar"
        case .charging: return "bolt.car"
        case .appliance: return "washer"
        case .job: return "hammer"
        case .timer: return "timer"
        }
    }
}

/// The phone's activity row at television scale. Kept beside the card rather
/// than shared with `LiveActivitiesView`: that one is compiled into the app
/// target only, and the two surfaces size their type independently.
private struct TVLiveActivityItemRow: View {
    let item: LiveActivityItem

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: item.icon ?? "circle.fill")
                    .font(.title3)
                    .foregroundStyle(item.status?.tint ?? .secondary)
                    .frame(width: 32)
                if let statusIcon = item.statusIcon {
                    Image(systemName: statusIcon)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                if let value = item.value {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        if let unit = item.unit {
                            Text(unit)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else if let status = item.status {
                    Text(status.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(status.tint)
                        .lineLimit(1)
                }
            }

            if let progress = item.progress {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(.linear)
                    .tint(item.status?.tint)
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
    let runningAction: TVRunningAction?
    let openLink: () -> Void
    let runAction: (ActionDefinition) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Button(action: openLink) {
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
                    case .summary, .action:
                        valueContent
                    }

                    if let deadline = card.deadline {
                        Label {
                            Text(deadline, style: .relative)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 220)
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
            .modifier(TVInertWhenUnlinked(isLinked: card.deepLink != nil))
            .accessibilityHint(card.deepLink == nil ? "" : "Shows a QR code for the web link")

            controls
        }
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
            Text(card.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            if let statusIcon = card.statusIcon {
                Image(systemName: statusIcon)
                    .font(.headline)
                    .foregroundStyle(card.status.tint)
            }
            StatusBadge(status: card.status, compact: true)
        }
    }

    private var valueContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(card.value ?? "—")\(card.unit ?? "")")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    /// Value and subtitle above a plot — a sparkline for `chart`, status pips
    /// for `history`, a segmented bar for `breakdown`. The tvOS card is a fixed 220pt tall and the plot needs a
    /// real share of it, so the headline is smaller here than `valueContent`
    /// draws it.
    @ViewBuilder
    private var chartContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(card.value ?? "—")\(card.unit ?? "")")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        if let chart = card.chart, chart.isRenderable {
            SparklineView(chart: chart, tint: card.status.tint, lineWidth: 3)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        if card.template == .history, let items = card.items, !items.isEmpty {
            StatusStripView(items: items, limit: 14, height: 20)
        }
        if card.template == .breakdown, let items = card.items, !items.isEmpty {
            CompositionBarView(items: items, tint: card.status.tint, height: 22)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if let items = card.items, !items.isEmpty {
            let fractions = RankedRows.fractions(for: items)
            VStack(spacing: 8) {
                ForEach(items.prefix(3)) { item in
                    HStack {
                        Text(item.title)
                            .lineLimit(1)
                        Spacer()
                        if let value = item.value {
                            Text("\(value)\(item.unit ?? "")")
                                .fontWeight(.semibold)
                                .foregroundStyle(item.status?.tint ?? .primary)
                        }
                    }
                    .font(.headline)
                    .padding(.horizontal, 6)
                    .background(alignment: .leading) {
                        if let fraction = fractions?[item.id] {
                            RankedRowBar(fraction: fraction, tint: item.status?.tint ?? card.status.tint)
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

    @ViewBuilder
    private var controls: some View {
        let actions = card.actions ?? []
        if !actions.isEmpty || card.deepLink != nil {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(actions) { action in
                        let isRunning = runningAction == TVRunningAction(
                            cardID: card.id,
                            actionID: action.id
                        )
                        Button {
                            runAction(action)
                        } label: {
                            HStack(spacing: 10) {
                                // Beside the label, never instead of it. A
                                // `ProgressView` alone has nothing to read, so
                                // the running button announced nothing at all
                                // and there was no way to hear which action
                                // was busy.
                                if isRunning {
                                    ProgressView()
                                }
                                Label(action.label, systemImage: actionIcon(action))
                            }
                        }
                        // This card only. Disabling every action on the
                        // dashboard moved focus off whatever the viewer had
                        // selected and never gave it back.
                        .disabled(runningAction?.cardID == card.id)
                        .accessibilityValue(isRunning ? "In progress" : "")
                    }

                    if card.deepLink != nil {
                        Button(action: openLink) {
                            Label("Open link", systemImage: "qrcode")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: 72)
        } else {
            Color.clear
                .frame(height: 72)
        }
    }

    private func actionIcon(_ action: ActionDefinition) -> String {
        action.role == .destructive ? "exclamationmark.triangle.fill" : "bolt.fill"
    }
}

/// Drops the button trait from a card that has nowhere to go.
///
/// Every card and every Live Activity on the dashboard is wrapped in a
/// `Button` so it can take focus and wear the system's card treatment, but a
/// producer is not required to send a `deepLink` and most do not. Such a card
/// announced itself as a button, and pressing Select did nothing at all — no
/// screen, no sound, no message, and nothing to distinguish it from a button
/// that had failed.
///
/// Removing the trait rather than the `Button` is deliberate: focus and the
/// card style are the reasons the button is there, and `.card` is a button
/// style with no non-button equivalent. What is wrong is the claim, not the
/// container.
private struct TVInertWhenUnlinked: ViewModifier {
    let isLinked: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLinked {
            content
        } else {
            content.accessibilityRemoveTraits(.isButton)
        }
    }
}

/// Which action is in flight, and on which card.
///
/// Was a `"\(card.id)|\(action.id)"` string, which the dashboard could only
/// compare whole — so "is anything running" was the finest question it could
/// ask, and the answer disabled every action button on screen.
private struct TVRunningAction: Equatable {
    let cardID: String
    let actionID: String
}

private struct TVPendingAction: Identifiable {
    let card: DashboardCard
    let action: ActionDefinition

    var id: String { "\(card.id)|\(action.id)" }
}
