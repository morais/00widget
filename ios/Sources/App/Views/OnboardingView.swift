import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var healthCheckTask: Task<Void, Never>?

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
                        .onChange(of: env.apiKey) { _, _ in
                            env.saveApiKey()
                            scheduleHealthCheck()
                        }
                    HStack {
                        Text("Health")
                        Spacer()
                        Text(healthStatusText)
                            .foregroundStyle(healthStatusColor)
                    }
                }

                if !env.notificationsAuthorized {
                    Section("Notifications") {
                        Button("Request notification permission") {
                            Task { await env.requestNotificationAuthorization() }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                await env.refreshNotificationAuthorization()
                await env.refreshConnectionHealth()
            }
            .onChange(of: env.serverBaseURL) { _, _ in scheduleHealthCheck() }
        }
    }

    private var healthStatusText: String {
        switch env.connectionHealth {
        case .unknown: return "-"
        case .notConfigured: return "Not configured"
        case .checking: return "Checking..."
        case .ok: return "OK"
        case .failed: return "Failed"
        }
    }

    private var healthStatusColor: Color {
        switch env.connectionHealth {
        case .unknown, .notConfigured, .checking: return .secondary
        case .ok: return .green
        case .failed: return .red
        }
    }

    private func scheduleHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await env.refreshConnectionHealth()
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
