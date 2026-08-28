import SwiftUI

/// What this install currently is: its identity, what it is allowed to do, and
/// how recently it heard from the server.
///
/// A drilldown under Diagnostics, beside the push and widget-refresh
/// references, and read-only like both of them. It was a build-gated debug
/// console until every control on it turned out to duplicate something the app
/// already does on its own; what was left is a window, and a window is worth
/// shipping — someone whose widgets are empty can read the reason here rather
/// than describe symptoms.
struct AppStateView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        Form {
            Section("Identity") {
                KeyValue(key: "Device ID", value: DeviceRegistration.deviceId())
                KeyValue(key: "App version", value: DeviceRegistration.appVersion())
                KeyValue(key: "Base URL", value: env.serverBaseURL)
            }

            Section {
                // Always "available" on a device. It is here for the case that
                // is not a device: a simulator build signed without the App
                // Group entitlement has no container, and every widget renders
                // empty with nothing else on screen to say why.
                KeyValue(key: "App Group", value: AppGroup.isAvailable ? "available" : "unavailable")
                KeyValue(key: "Connection health", value: connectionHealthText)
                KeyValue(
                    key: "Notifications",
                    value: env.notificationsAuthorized ? "authorized" : "not authorized"
                )
                // The app's own APNs token, which is not the one on the push
                // registration screen — that is WidgetKit's, issued to the
                // extension. Both are named in full wherever they appear.
                KeyValue(
                    key: "App push token",
                    value: env.apnsDeviceToken.map { String($0.prefix(16)) + "..." } ?? "not available"
                )
            } header: {
                Text("Capabilities")
            }

            Section("Sync") {
                KeyValue(key: "Cached cards", value: "\(env.cards.count)")
                KeyValue(key: "Active activities", value: "\(env.liveActivityController.activeIds.count)")
                if let lastSyncAt = env.lastSyncAt {
                    KeyValue(
                        key: "Last sync",
                        value: lastSyncAt.formatted(.relative(presentation: .numeric))
                    )
                } else {
                    KeyValue(key: "Last sync", value: "never")
                }
                if let lastSyncError = env.lastSyncError {
                    KeyValue(key: "Last error", value: lastSyncError)
                }
            }
        }
        .navigationTitle("App state")
        .navigationBarTitleDisplayMode(.inline)
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
