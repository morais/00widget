import SwiftUI

struct LiveActivitiesView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject private var liveActivityController = LiveActivityController.shared
    @State private var isGeneratingSample = false
    @State private var sampleError: String?
    #if ZW_SHARING_ENABLED
    @State private var shareKind: LiveActivityKind?
    #endif

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Activities")
                .refreshable { await liveActivityController.reconcileWithServer() }
                .task { await liveActivityController.reconcileWithServer() }
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
            if liveActivityController.activeSessions.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                LazyVStack(spacing: 12) {
                    if hasSampleActivities { sampleNotice }
                    ForEach(liveActivityController.activeSessions) { session in
                        ActivityCard(session: session)
                        #if ZW_SHARING_ENABLED
                        .contextMenu {
                            Button {
                                shareKind = session.kind
                            } label: {
                                Label("Share \(session.kind.rawValue) activities", systemImage: "person.crop.circle.badge.plus")
                            }
                        }
                        #endif
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

            if liveActivityController.supported {
                Button("Generate sample activity") {
                    Task { await generateSample() }
                }
                .buttonStyle(.bordered)
                .disabled(isGeneratingSample)

                Text("The sample runs only on this device and can be removed at any time.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 32)

                if let sampleError {
                    Text(sampleError)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
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
                Task { await liveActivityController.endSamples() }
            }
            .buttonStyle(.bordered)
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
        } catch {
            sampleError = "Could not start the sample: \(error.localizedDescription)"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.headline)
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
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if activeItems.isEmpty {
                    trailingValue
                }
            }

            if !activeItems.isEmpty {
                VStack(spacing: 10) {
                    ForEach(activeItems) { item in
                        ActivityItemRow(item: item)
                    }
                }
            } else if let progress = session.progress, session.endsAt == nil {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(.linear)
            }

            Text(session.externalActivityId)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var stateBadge: some View {
        Text("Active")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.16)))
            .foregroundStyle(.secondary)
    }

    private var activeItemBadge: some View {
        Text("\(activeItems.count) active")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.blue.opacity(0.14)))
            .foregroundStyle(.blue)
    }

    @ViewBuilder
    private var trailingValue: some View {
        if let endsAt = session.endsAt {
            LiveActivityCountdownText(
                endsAt: endsAt,
                granularity: session.countdownGranularity
            )
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
        } else if let value = session.value {
            VStack(alignment: .trailing, spacing: 0) {
                Text(value).font(.title3.weight(.semibold))
                if let unit = session.unit {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(session.state.capitalized)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.16)))
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
}

private struct ActivityItemRow: View {
    let item: LiveActivityItem

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: item.icon ?? "circle.fill")
                    .font(.body)
                    .foregroundStyle(item.status?.tint ?? .secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if let value = item.value {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
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
                        .foregroundStyle(status.tint)
                }
            }

            if let progress = item.progress {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(.linear)
                    .tint(item.status?.tint)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
