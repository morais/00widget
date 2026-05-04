import SwiftUI

struct LiveActivitiesView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject private var liveActivityController = LiveActivityController.shared
    @State private var errorText: String?
    #if ZW_SHARING_ENABLED
    @State private var shareKind: LiveActivityKind?
    #endif

    private var rows: [ActivityRowModel] {
        let activeRows = liveActivityController.activeSessions.map {
            ActivityRowModel(session: $0, state: .active)
        }
        let activeIds = Set(activeRows.map(\.id))
        let pendingRows = env.pendingActivities
            .filter { !activeIds.contains($0.id) }
            .map { ActivityRowModel(session: $0, state: .pending) }

        return activeRows + pendingRows
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Activities")
                .refreshable { await refreshActivities() }
                .task { await refreshActivities() }
                .onAppear {
                    Task { await refreshActivities() }
                }
                #if ZW_SHARING_ENABLED
                .sheet(item: $shareKind) { kind in
                    ShareActivityKindSheet(kind: kind)
                        .environmentObject(env)
                }
                #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if rows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(rows) { row in
                        ActivityCard(
                            row: row,
                            start: { Task { await start(row.session) } },
                            update: { Task { await update(row.session) } },
                            end: { Task { await end(row.session) } }
                        )
                        #if ZW_SHARING_ENABLED
                        .contextMenu {
                            Button {
                                shareKind = row.session.kind
                            } label: {
                                Label("Share \(row.session.kind.rawValue) activities", systemImage: "person.crop.circle.badge.plus")
                            }
                        }
                        #endif
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("No activities yet")
                .font(.headline)
            Text(emptyMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Generate sample activities") {
                Task { await startSample() }
            }
            .buttonStyle(.borderedProminent)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding()
    }

    private var emptyMessage: String {
        if liveActivityController.supported {
            return "Start one from your agent, or tap below to generate local samples."
        } else {
            return "Live Activities are not enabled on this device."
        }
    }

    private func refreshActivities() async {
        liveActivityController.refresh()
        await env.refreshPendingActivities()
        liveActivityController.refresh()
    }

    private func startSample() async {
        await start(SampleDataFactory.makeLiveActivitySession())
    }

    private func start(_ session: LiveActivitySession) async {
        errorText = nil
        do {
            try await liveActivityController.start(session)
            await refreshActivities()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func update(_ session: LiveActivitySession) async {
        var updated = session
        updated.progress = min((updated.progress ?? 0) + 0.25, 1)
        updated.state = updated.progress == 1 ? "complete" : "running"
        updated.subtitle = updated.progress == 1 ? "Cycle complete" : "Updated just now"
        updated.updatedAt = Date()
        await liveActivityController.update(updated)
        await refreshActivities()
    }

    private func end(_ session: LiveActivitySession) async {
        await liveActivityController.end(externalActivityId: session.externalActivityId)
        await refreshActivities()
    }
}

private struct ActivityRowModel: Identifiable {
    enum State {
        case active
        case pending
    }

    let session: LiveActivitySession
    let state: State

    var id: String { session.id }
}

private struct ActivityCard: View {
    let row: ActivityRowModel
    let start: () -> Void
    let update: () -> Void
    let end: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.session.title)
                            .font(.headline)
                        stateBadge
                    }

                    if let subtitle = row.session.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text("Updated \(row.session.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                trailingValue
            }

            if let progress = row.session.progress, row.session.endsAt == nil {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(.linear)
            }

            HStack {
                Text(row.session.externalActivityId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer()

                switch row.state {
                case .pending:
                    Button("Start") { start() }
                        .buttonStyle(.bordered)
                case .active:
                    Button("Update") { update() }
                        .buttonStyle(.bordered)
                    Button("End", role: .destructive) { end() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var stateBadge: some View {
        Text(row.state == .active ? "Active" : "Pending")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.16)))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var trailingValue: some View {
        if let endsAt = row.session.endsAt {
            Text(endsAt, style: .timer)
                .font(.headline)
                .monospacedDigit()
        } else if let value = row.session.value {
            VStack(alignment: .trailing, spacing: 0) {
                Text(value).font(.title3.weight(.semibold))
                if let unit = row.session.unit {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(row.session.state.capitalized)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.16)))
        }
    }

    private var iconName: String {
        if let icon = row.session.icon {
            return icon
        }

        switch row.session.kind {
        case .generic: return "square.dashed"
        case .progress: return "chart.bar"
        case .charging: return "bolt.car"
        case .appliance: return "washer"
        case .job: return "hammer"
        case .timer: return "timer"
        }
    }
}
