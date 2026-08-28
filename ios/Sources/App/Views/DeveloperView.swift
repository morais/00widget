import SwiftUI

/// Read-only diagnostics, gated behind the `ZW_DEBUG_TOOLS` build setting and
/// compiled out of every shipping build.
///
/// Deliberately without controls. Everything it once offered either duplicated
/// something the app does on its own — registering the device, fetching cards,
/// a health check the Settings screen already runs — or belonged on
/// `DeveloperOptionsView`, which a curious owner reaches by tapping the version
/// number and which is where anything a user might legitimately want goes.
/// Keep it a window, not a control panel.
struct DeveloperView: View {
    @EnvironmentObject var env: AppEnvironment

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
            }
            .navigationTitle("Debug")
        }
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
