import SwiftUI

/// The debug console, gated behind the `ZW_DEBUG_TOOLS` build setting and
/// compiled out of every shipping build.
///
/// Distinct from `DeveloperOptionsView`, which a curious owner can reach in a
/// released app by tapping the version number. Anything here is for someone
/// working on the app; anything a user might legitimately want — including
/// "Hide sample indicators", which is as useful for a screen recording as it
/// is for the marketing shots — belongs on that screen instead.
struct DeveloperView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var logLines: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("State") {
                    KeyValue(key: "App Group", value: AppGroup.isAvailable ? "available" : "unavailable")
                    KeyValue(key: "Device ID", value: DeviceRegistration.deviceId())
                    KeyValue(key: "App version", value: DeviceRegistration.appVersion())
                    KeyValue(key: "Base URL", value: env.serverBaseURL)
                    KeyValue(key: "Connection health", value: connectionHealthText)
                    KeyValue(
                        key: "Notifications",
                        value: env.notificationsAuthorized ? "authorized" : "not authorized"
                    )
                    KeyValue(
                        key: "APNs device token",
                        value: env.apnsDeviceToken.map { String($0.prefix(16)) + "..." } ?? "not available"
                    )
                    KeyValue(key: "Cached cards", value: "\(env.cards.count)")
                    KeyValue(key: "Activities tab", value: env.showActivitiesTab ? "visible" : "hidden")
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
                    Toggle("Show Activities tab", isOn: $env.showActivitiesTab)
                    Button("Test backend connection") {
                        Task {
                            let ok = await env.testConnection()
                            append(ok ? "health: ok" : "health: failed")
                        }
                    }
                    Button("Register device") { Task { await env.registerDevice(); append("registerDevice done") } }
                    Button("Fetch cards") { Task { await env.fetchCards(); append("fetchCards \(env.cards.count)") } }
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

    private var connectionHealthText: String {
        switch env.connectionHealth {
        case .unknown: return "unknown"
        case .notConfigured: return "not configured"
        case .checking: return "checking"
        case .ok: return "ok"
        case .failed: return "failed"
        }
    }
}
