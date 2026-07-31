import SwiftUI

struct TVDashboardView: View {
    @EnvironmentObject var env: TVEnvironment
    @State private var showingSettings = false
    @State private var selectedLink: TVWebLink?
    @State private var pendingAction: TVPendingAction?
    @State private var runningActionID: String?
    @State private var actionError: String?
    @FocusState private var settingsFocused: Bool

    private let widgetColumns = Array(
        repeating: GridItem(.flexible(), spacing: 40, alignment: .top),
        count: 3
    )
    private let activityColumns = [GridItem(.flexible(), alignment: .top)]

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
        .fullScreenCover(isPresented: $showingSettings) {
            TVSettingsView()
                .environmentObject(env)
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
                            columns: activityColumns
                        ) {
                            ForEach(env.liveActivities) { activity in
                                TVLiveActivityCardView(
                                    activity: activity,
                                    openLink: { openLink(for: activity) },
                                    focusSettings: { settingsFocused = true }
                                )
                            }
                        }
                    }

                    if !env.cards.isEmpty {
                        dashboardSection(
                            title: "Widgets",
                            icon: "square.grid.2x2",
                            columns: widgetColumns
                        ) {
                            ForEach(env.cards) { card in
                                TVDashboardCardView(
                                    card: card,
                                    runningActionID: runningActionID,
                                    openLink: { openLink(for: card) },
                                    runAction: { request($0, for: card) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
    }

    private func dashboardSection<Content: View>(
        title: String,
        icon: String,
        columns: [GridItem],
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(title, systemImage: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                content()
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
        let actionID = "\(card.id)|\(action.id)"
        runningActionID = actionID
        actionError = nil

        Task {
            defer { runningActionID = nil }
            guard let client = env.apiClient() else {
                actionError = "The server connection is unavailable."
                return
            }
            do {
                try await client.runAction(id: action.id, cardId: card.id, source: "app")
                await env.fetchCards()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct TVLiveActivityCardView: View {
    let activity: LiveActivitySession
    let openLink: () -> Void
    let focusSettings: () -> Void

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
                        }
                        Spacer(minLength: 12)
                        trailingValue
                    }

                    if let progress = activity.progress, activity.endsAt == nil {
                        ProgressView(value: max(0, min(progress, 1)))
                            .tint(.accentColor)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 220)
                .contentShape(RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(.card)
            .onMoveCommand { direction in
                if direction == .up {
                    focusSettings()
                }
            }
            .accessibilityHint(
                activity.deepLink == nil
                    ? "Live Activity summary"
                    : "Shows a QR code for the activity link"
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

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
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
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                .foregroundStyle(Color.accentColor)
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
        } else {
            Text(activity.state.capitalized)
                .font(.title3.weight(.semibold))
        }
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

private struct TVDashboardCardView: View {
    let card: DashboardCard
    let runningActionID: String?
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
                    case .summary, .action:
                        valueContent
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 220)
                .contentShape(RoundedRectangle(cornerRadius: 24))
            }
            .buttonStyle(.card)
            .accessibilityHint(card.deepLink == nil ? "Widget summary" : "Shows a QR code for the web link")

            controls
        }
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

    @ViewBuilder
    private var listContent: some View {
        if let items = card.items, !items.isEmpty {
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
                        let actionID = "\(card.id)|\(action.id)"
                        Button {
                            runAction(action)
                        } label: {
                            if runningActionID == actionID {
                                ProgressView()
                                    .frame(minWidth: 120)
                            } else {
                                Label(action.label, systemImage: actionIcon(action))
                            }
                        }
                        .disabled(runningActionID != nil)
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

private struct TVPendingAction: Identifiable {
    let card: DashboardCard
    let action: ActionDefinition

    var id: String { "\(card.id)|\(action.id)" }
}
