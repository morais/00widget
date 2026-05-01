import AuthenticationServices
import SwiftUI
import UIKit

struct OnboardingView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var healthCheckTask: Task<Void, Never>?
    @State private var copiedToken = false
    @State private var copiedAgentConfig = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    if ZeroZeroWidgetConstants.appleLoginEnabled {
                        KeyValue(key: "API URL", value: env.serverBaseURL)
                    } else {
                        TextField("https://example.workers.dev", text: $env.serverBaseURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    if ZeroZeroWidgetConstants.appleLoginEnabled {
                        appleLoginControls
                    } else {
                        SecureField("API key", text: $env.apiKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .onChange(of: env.apiKey) { _, _ in
                                env.saveApiKey()
                                scheduleHealthCheck()
                            }
                    }
                    if env.connectionHealth != .notConfigured {
                        HStack {
                            Text("Health")
                            Spacer()
                            Text(healthStatusText)
                                .foregroundStyle(healthStatusColor)
                        }
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

    @ViewBuilder
    private var appleLoginControls: some View {
        if env.appleLoginInProgress {
            ProgressView("Signing in...")
        }

        if !env.apiKey.isEmpty {
            if let email = env.appleLoginEmail {
                KeyValue(key: "Signed in", value: email)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(env.apiKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
                Button(copiedToken ? "Copied" : "Copy token") {
                    UIPasteboard.general.string = env.apiKey
                    copiedToken = true
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Agent config")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(agentConfig)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                Button(copiedAgentConfig ? "Copied" : "Copy agent config") {
                    UIPasteboard.general.string = agentConfig
                    copiedAgentConfig = true
                }
            }

            Button("Sign out", role: .destructive) {
                env.clearApiKey()
                copiedToken = false
                copiedAgentConfig = false
                scheduleHealthCheck()
            }
        } else {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                handleAppleSignIn(result)
            }
            .frame(height: 44)
            .disabled(env.appleLoginInProgress)
        }

        if let error = env.appleLoginError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                return
            }
            Task {
                await env.signInWithAppleIdentityToken(identityToken)
                scheduleHealthCheck()
            }
        case .failure:
            break
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

    private var agentConfig: String {
        "Integrate with 00Widget. Use \(env.serverBaseURL) as the API base URL; it also has the integration instructions. Use this bearer token: \(env.apiKey)"
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
