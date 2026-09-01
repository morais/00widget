import SwiftUI

struct LiveActivitiesView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject private var liveActivityController = LiveActivityController.shared
    @State private var isGeneratingSample = false
    @State private var sampleError: String?
    /// See the note in `CardDetailView`: an announcement says what happened,
    /// focus is what lets it be read again.
    @AccessibilityFocusState private var sampleErrorFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Activities")
                .refreshable { await liveActivityController.reconcileWithServer() }
                .task {
                    #if ZW_SCREENSHOTS
                    // ActivityKit survives app reinstalls and previous capture
                    // runs. Replace the retained local sample so changes to
                    // the marketing data appear on the very next run.
                    await liveActivityController.endSamples()
                    try? await liveActivityController.startSample()
                    #endif
                    await liveActivityController.reconcileWithServer()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if liveActivityController.activeSessions.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                LazyVStack(spacing: 12) {
                    if hasSampleActivities { sampleNotice }
                    ForEach(liveActivityController.activeSessions) { session in
                        NavigationLink {
                            ActivityDetailView(session: session)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                if env.guestActivities.contains(where: { $0.id == session.id }) {
                                    Label("Read-only link", systemImage: "link")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                ActivityCard(session: session, combinesAccessibility: true)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            // "Right now", not "yet": an empty list is the normal resting
            // state, not a device that has never seen one. Activities end and
            // the screen is empty again — "yet" would tell someone whose
            // morning deploy finished that nothing had ever run. It stays the
            // same sentence where ActivityKit is unavailable, because this
            // page still lists activities the server reports; only starting
            // one locally is off, which the message below says.
            Text("No activities right now")
                .font(.headline)
            Text(emptyMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            if liveActivityController.supported {
                Button("Generate sample activity") {
                    Task { await generateSample() }
                }
                .buttonStyle(.bordered)
                .disabled(isGeneratingSample)

                Text("The sample runs only on this device and can be removed at any time.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                if let sampleError {
                    Text(sampleError)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                        .accessibilityFocused($sampleErrorFocused)
                }
            }
        }
        .padding()
    }

    private var hasSampleActivities: Bool {
        !SharedSettings.hideSampleIndicators
            && liveActivityController.activeSessions.contains { $0.isSample }
    }

    /// Mirrors the Dashboard's sample notice: demo state is always labelled as
    /// such, and is always removable from the screen that shows it.
    private var sampleNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This is a sample", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))

            Text("This Live Activity was generated on this device to show what 00Widget looks like. No agent started it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Remove sample activity", role: .destructive) {
                Task {
                    await liveActivityController.endSamples()
                    AccessibilityAnnouncement.post("Sample activity removed.")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func generateSample() async {
        isGeneratingSample = true
        sampleError = nil
        defer { isGeneratingSample = false }
        do {
            try await liveActivityController.startSample()
            // The list this replaces the empty state with is somewhere else on
            // the screen entirely, so without this the button reports nothing.
            AccessibilityAnnouncement.post("Sample activity started.")
        } catch {
            sampleError = "Could not start the sample: \(error.localizedDescription)"
            AccessibilityAnnouncement.post("Could not start the sample activity. \(error.localizedDescription)")
            sampleErrorFocused = true
        }
    }

    private var emptyMessage: String {
        if liveActivityController.supported {
            return "Live Activities appear automatically when one of your agents starts them."
        } else {
            return "Live Activities are not enabled on this device."
        }
    }
}

private struct ActivityCard: View {
    let session: LiveActivitySession
    let combinesAccessibility: Bool
    let showsChart: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        session: LiveActivitySession,
        combinesAccessibility: Bool = false,
        showsChart: Bool = true
    ) {
        self.session = session
        self.combinesAccessibility = combinesAccessibility
        self.showsChart = showsChart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            headerLayout {
                VStack(spacing: 2) {
                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundStyle(session.tint)
                    // What the activity is doing right now, under what it is.
                    if let statusIcon = session.semanticStatusIcon {
                        Image(systemName: statusIcon)
                            .font(.caption)
                            .foregroundStyle(session.tint)
                    }
                }
                .frame(width: 32)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    let titleLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(spacing: 8))
                    titleLayout {
                        Text(session.title)
                            .font(.headline)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        if activeItems.isEmpty {
                            stateBadge
                        } else {
                            activeItemBadge
                        }
                    }

                    if let subtitle = session.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text("Updated \(session.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer()
                }

                // A composite activity normally summarises itself with the
                // per-item rows below, but a producer-sent `value` outranks
                // that and keeps its slot.
                if activeItems.isEmpty || hasExplicitValue {
                    trailingValue
                }
            }

            if !activeItems.isEmpty {
                VStack(spacing: 10) {
                    ForEach(activeItems) { item in
                        ActivityItemRow(item: item)
                    }
                }
            } else if let progress = session.progress, session.endsAt == nil, session.chart == nil {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(.linear)
                    .tint(session.tint)
            }

            // Unlike the Lock Screen banner, the app card can afford the plot
            // alongside item rows, so it is drawn whenever one was published.
            //
            // It takes an item row's surface rather than sitting bare on the
            // card. An area fill ends in a hard horizontal edge by
            // construction, and against the card's own background — white on
            // white in light mode — that edge reads as the plot bleeding out
            // of a clipped container rather than as the bottom of a chart.
            if showsChart, let chart = session.chart, chart.isRenderable {
                SparklineView(chart: chart, tint: session.tint, lineWidth: 2)
                    .frame(height: 56)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                // This screen is not hosted by a grouped list, where
                // secondarySystemGroupedBackground would contrast with its
                // parent. Here it resolves to the same white as the page and
                // makes the activity container disappear around the chart.
                .fill(Color(.systemGray6))
        )
        .modifier(
            LiveActivityAccessibilityModifier(
                session: session,
                combinesChildren: combinesAccessibility
            )
        )
    }

    private var stateBadge: some View {
        Label {
            Text("Active")
        } icon: {
            if let signal = session.signal {
                Image(systemName: signal.symbolName)
            }
        }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(session.tint.opacity(0.16)))
            .foregroundStyle(.primary)
    }

    private var activeItemBadge: some View {
        Text("\(activeItems.count) active")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.blue.opacity(0.14)))
            .foregroundStyle(.primary)
    }

    /// An explicit `value` outranks the countdown, matching the Lock Screen,
    /// where the header shows the producer's value and the countdowns live on
    /// the item rows. Ranking the countdown first dropped the value entirely —
    /// on a queue activity the ticket now being served vanished, leaving only
    /// an estimate of when yours comes up. Both fit here, so both are drawn.
    @ViewBuilder
    private var trailingValue: some View {
        if hasExplicitValue, let value = session.value {
            VStack(alignment: .trailing, spacing: 0) {
                Text(value).font(.title3.weight(.semibold))
                if let unit = session.unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                if let endsAt = session.endsAt {
                    LiveActivityCountdownText(
                        endsAt: endsAt,
                        granularity: session.countdownGranularity
                    )
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let endsAt = session.endsAt {
            LiveActivityCountdownText(
                endsAt: endsAt,
                granularity: session.countdownGranularity
            )
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Text(session.state.capitalized)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(session.tint.opacity(0.16)))
        }
    }

    private var iconName: String {
        if let icon = session.icon {
            return icon
        }

        switch session.kind {
        case .generic: return "square.dashed"
        case .progress: return "chart.bar"
        case .charging: return "bolt.car"
        case .appliance: return "washer"
        case .job: return "hammer"
        case .timer: return "timer"
        }
    }

    private var activeItems: [LiveActivityItem] {
        (session.items ?? []).filter(\.isActive)
    }

    private var hasExplicitValue: Bool {
        !(session.value ?? "").isEmpty
    }
}

private struct ActivityDetailView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject private var liveActivityController = LiveActivityController.shared
    let session: LiveActivitySession
    @State private var showGuestLinkSheet = false
    #if ZW_SHARING_ENABLED
    @State private var showKindShareSheet = false
    #endif

    var body: some View {
        let currentSession = resolvedSession
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ActivityCard(session: currentSession, showsChart: false)

                if let chart = currentSession.chart, chart.isRenderable {
                    InspectableChartView(
                        chart: chart,
                        tint: currentSession.tint,
                        title: currentSession.title,
                        unit: currentSession.unit,
                        plotHeight: 180,
                        lineWidth: 3
                    )
                }

                if let deepLink = currentSession.deepLink {
                    Link(destination: deepLink) {
                        Label("Open link", systemImage: "arrow.up.forward.app")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    deepLinkDestination(deepLink)
                }

                RawPayloadDisclosure(
                    payload: currentSession,
                    endpoint: "/v1/live-activities/start"
                )

                // A guest link is the only way another account's activity
                // reaches this screen; there is no sharedBy on a session the
                // way there is on a card.
                if isGuestActivity {
                    HStack {
                        Spacer()
                        ReportProblemLink()
                            .font(.footnote)
                    }
                }
            }
            .padding()
        }
        .refreshable { await liveActivityController.reconcileWithServer() }
        .navigationTitle(currentSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A sample has no server-side instance to bind a link to, and a
            // guest's own activity is not theirs to pass on.
            if let instanceId = currentSession.activityInstanceId, !isGuestActivity {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showGuestLinkSheet = true
                        } label: {
                            Label("Share this activity as a link", systemImage: "qrcode")
                        }
                        #if ZW_SHARING_ENABLED
                        Button {
                            showKindShareSheet = true
                        } label: {
                            Label(
                                "Share all \(currentSession.kind.rawValue) activities…",
                                systemImage: "person.crop.circle.badge.plus"
                            )
                        }
                        #endif
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-activity-link")
                    .id(instanceId)
                }
            }
        }
        .sheet(isPresented: $showGuestLinkSheet) {
            if let instanceId = currentSession.activityInstanceId {
                GuestLinkShareSheet(
                    resourceKind: "activity",
                    resourceId: instanceId,
                    title: currentSession.title
                )
                .environmentObject(env)
            }
        }
        #if ZW_SHARING_ENABLED
        .sheet(isPresented: $showKindShareSheet) {
            ShareActivityKindSheet(kind: currentSession.kind)
                .environmentObject(env)
        }
        #endif
    }

    private var isGuestActivity: Bool {
        env.guestActivities.contains { $0.id == session.id }
    }

    private var resolvedSession: LiveActivitySession {
        liveActivityController.activeSessions.first { $0.id == session.id } ?? session
    }

    private func deepLinkDestination(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Destination")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(deepLinkDisplay(url))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func deepLinkDisplay(_ url: URL) -> String {
        guard
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            let host = url.host
        else {
            return url.absoluteString
        }
        return "\(scheme)://\(host)"
    }

}

private struct ActivityItemRow: View {
    let item: LiveActivityItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 6) {
            let rowLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            rowLayout {
                Image(systemName: item.icon ?? "circle.fill")
                    .font(.body)
                    .foregroundStyle(item.tint())
                    .frame(width: 24, height: 24)
                if let statusIcon = item.statusIcon {
                    Image(systemName: statusIcon)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        SemanticFlowIcon(item.semantic)
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    }
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                }

                if let value = item.value {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.title3.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        if let unit = item.unit {
                            Text(unit)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else if let status = item.status {
                    Text(status.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }

            if let progress = item.progress {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(.linear)
                    .tint(item.tint())
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LiveActivityAccessibilitySummary.summary(for: item)))
        .accessibilityInputLabels([item.title])
    }
}

private struct LiveActivityAccessibilityModifier: ViewModifier {
    let session: LiveActivitySession
    let combinesChildren: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if combinesChildren {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(LiveActivityAccessibilitySummary.summary(for: session)))
                // "Tap Washer" — see the note on `CardAccessibilityModifier`.
                .accessibilityInputLabels([session.title])
        } else {
            content
        }
    }
}
