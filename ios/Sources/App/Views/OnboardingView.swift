import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var healthStatus: HealthStatus = .unknown
    @State private var notificationsAuthorized: Bool = false

    enum HealthStatus { case unknown, ok, failed }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://example.workers.dev", text: $env.serverBaseURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("API key", text: $env.apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .onChange(of: env.apiKey) { _, _ in env.saveApiKey() }
                }

                Section("Connection") {
                    Button("Test backend connection") {
                        Task {
                            let ok = await env.testConnection()
                            healthStatus = ok ? .ok : .failed
                        }
                    }
                    HStack {
                        Text("Health")
                        Spacer()
                        Text(healthStatusText)
                            .foregroundStyle(healthStatusColor)
                    }
                    Button("Register device") {
                        Task { await env.registerDevice() }
                    }
                }

                Section("Notifications") {
                    Button("Request notification permission") {
                        Task {
                            notificationsAuthorized = await DeviceRegistration.requestNotificationAuthorization()
                            if notificationsAuthorized {
                                await MainActor.run { DeviceRegistration.registerForRemoteNotifications() }
                            }
                        }
                    }
                    HStack {
                        Text("APNs device token")
                        Spacer()
                        Text(env.apnsDeviceToken.map { String($0.prefix(8)) + "…" } ?? "not available")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Section("Status") {
                    KeyValue(key: "App Group", value: AppGroup.isAvailable ? "available" : "unavailable")
                    KeyValue(key: "Device ID", value: DeviceRegistration.deviceId())
                    KeyValue(key: "App version", value: DeviceRegistration.appVersion())
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var healthStatusText: String {
        switch healthStatus {
        case .unknown: return "—"
        case .ok: return "OK"
        case .failed: return "Failed"
        }
    }

    private var healthStatusColor: Color {
        switch healthStatus {
        case .unknown: return .secondary
        case .ok: return .green
        case .failed: return .red
        }
    }
}

struct KeyValue: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
