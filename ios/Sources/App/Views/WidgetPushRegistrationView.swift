import SwiftUI

/// What WidgetKit handed this device, what the server has acknowledged, and a
/// button to send the saved snapshot again.
///
/// A drilldown rather than a section on `DeveloperOptionsView`: six read-only
/// rows that only matter when push is being diagnosed, and the parent screen is
/// otherwise a short list of switches.
struct WidgetPushRegistrationView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var snapshot = WidgetPushTokenStore.load()
    @State private var registering = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Current build", value: ZeroZeroWidgetConstants.appVersion)
                // Named in full because App state shows the app's own APNs
                // token one row away in the same section, and they differ.
                LabeledContent(
                    "Widget push token",
                    value: snapshot?.pushToken.map { "\($0.prefix(8))…" } ?? "Unavailable"
                )
                LabeledContent("Snapshot updated", value: formatted(snapshot?.updatedAt))
                LabeledContent("Server acknowledged", value: formatted(snapshot?.registeredAt))
                LabeledContent(
                    "Acknowledged build",
                    value: snapshot?.registeredAppVersion ?? "Never"
                )
                LabeledContent(
                    "Subscribed kinds",
                    value: "\(snapshot?.subscriptions.count ?? 0)"
                )
                if let status = env.widgetPushRegistrationStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(registering ? "Registering…" : "Re-register widget push") {
                    registering = true
                    Task {
                        await env.forceRegisterSavedWidgetPushSnapshot()
                        snapshot = WidgetPushTokenStore.load()
                        registering = false
                    }
                }
                .disabled(registering)
            } footer: {
                Text("The app sends this saved snapshot directly once on every launch, then asks WidgetKit for any newer token or configuration. The button repeats the direct send without waiting for WidgetKit.")
            }
        }
        .navigationTitle("Push registration")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
