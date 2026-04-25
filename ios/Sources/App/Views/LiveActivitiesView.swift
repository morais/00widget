import SwiftUI

struct LiveActivitiesView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Local activities") {
                    if env.liveActivityController.supported == false {
                        Text("Live Activities are not enabled on this device.")
                            .foregroundStyle(.secondary)
                    }
                    if env.liveActivityController.activeIds.isEmpty {
                        Text("No active activities")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(env.liveActivityController.activeIds, id: \.self) { id in
                            Text(id).font(.caption.monospaced())
                        }
                    }
                }

                Section("Sample") {
                    Button("Start sample activity") {
                        Task { await startSample() }
                    }
                    Button("Update sample activity") {
                        Task { await updateSample() }
                    }
                    Button("End sample activity", role: .destructive) {
                        Task {
                            await env.liveActivityController.end(externalActivityId: SampleDataFactory.makeLiveActivitySession().externalActivityId)
                        }
                    }
                }

                Section("Pending from server") {
                    if env.pendingActivities.isEmpty {
                        Text("No pending activities")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(env.pendingActivities) { activity in
                            VStack(alignment: .leading) {
                                Text(activity.title).font(.headline)
                                if let subtitle = activity.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Start locally") {
                                    Task { try? await env.liveActivityController.start(activity) }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    Button("Refresh") { Task { await env.refreshPendingActivities() } }
                }

                if let errorText {
                    Section("Error") {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Activities")
        }
    }

    private func startSample() async {
        errorText = nil
        do {
            try await env.liveActivityController.start(SampleDataFactory.makeLiveActivitySession())
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func updateSample() async {
        var session = SampleDataFactory.makeLiveActivitySession()
        session.progress = 0.75
        session.state = "rinse"
        session.subtitle = "Rinse cycle"
        session.updatedAt = Date()
        await env.liveActivityController.update(session)
    }
}
