import SwiftUI

struct DeveloperView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var logLines: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("State") {
                    KeyValue(key: "Device ID", value: DeviceRegistration.deviceId())
                    KeyValue(key: "Base URL", value: env.serverBaseURL)
                    KeyValue(key: "Cached cards", value: "\(env.cards.count)")
                    KeyValue(key: "Active activities", value: "\(env.liveActivityController.activeIds.count)")
                    if let ts = env.lastSyncAt {
                        KeyValue(key: "Last sync", value: ts.formatted(.relative(presentation: .numeric)))
                    } else {
                        KeyValue(key: "Last sync", value: "never")
                    }
                    if let err = env.lastSyncError {
                        KeyValue(key: "Last error", value: err)
                    }
                }

                Section("Actions") {
                    Button("Test backend connection") {
                        Task {
                            let ok = await env.testConnection()
                            append(ok ? "health: ok" : "health: failed")
                        }
                    }
                    Button("Register device") { Task { await env.registerDevice(); append("registerDevice done") } }
                    Button("Fetch cards") { Task { await env.fetchCards(); append("fetchCards \(env.cards.count)") } }
                    Button("Refresh pending activities") { Task { await env.refreshPendingActivities(); append("pending \(env.pendingActivities.count)") } }
                    Button("Generate sample cards") { env.generateSampleCards(); append("generated \(env.cards.count)") }
                    Button("Start sample activity") {
                        Task {
                            do {
                                try await env.liveActivityController.start(SampleDataFactory.makeLiveActivitySession())
                                append("sample activity started")
                            } catch {
                                append("start failed: \(error.localizedDescription)")
                            }
                        }
                    }
                    Button("Clear cache", role: .destructive) { env.clearCache(); append("cache cleared") }
                }

                Section("Log") {
                    if logLines.isEmpty {
                        Text("No entries").foregroundStyle(.secondary).font(.caption)
                    } else {
                        ForEach(logLines.reversed(), id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Debug")
        }
    }

    private func append(_ line: String) {
        let ts = Date().formatted(.dateTime.hour().minute().second())
        logLines.append("[\(ts)] \(line)")
    }
}
