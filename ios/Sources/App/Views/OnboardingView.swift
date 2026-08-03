import AuthenticationServices
import CryptoKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var healthCheckTask: Task<Void, Never>?
    @State private var copiedToken = false
    @State private var copiedAgentConfig = false
    // Raw nonce for the in-flight Sign in with Apple request. We hash it
    // (SHA-256) before handing it to ASAuthorizationAppleIDRequest so Apple
    // logs only the hash, and we send the raw value to the backend so it can
    // re-derive the same hash and compare against the id_token's nonce claim.
    @State private var pendingAppleRawNonce: String?

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
                        if env.notificationsDenied {
                            Text("Notifications are blocked. Enable them in System Settings to receive widget updates.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        } else {
                            Button("Request notification permission") {
                                Task { await env.requestNotificationAuthorization() }
                            }
                        }
                    }
                }

                Section("Widgets") {
                    NavigationLink("How to add a widget") {
                        WidgetSetupGuideView()
                    }
                }

                Section("Agent config") {
                    Text(agentConfig)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(copiedAgentConfig ? "Copied temporarily" : "Copy agent config") {
                        copySensitiveText(agentConfig)
                        copiedAgentConfig = true
                    }
                }

                #if ZW_SHARING_ENABLED
                Section("Sharing") {
                    NavigationLink("Manage sharing") {
                        SharingView()
                    }
                }
                #endif

                Section("About") {
                    KeyValue(key: "Version", value: appVersionString)
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
                Text("Agent publisher token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(env.agentApiKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
                Button(copiedToken ? "Copied temporarily" : "Copy token") {
                    copySensitiveText(env.agentApiKey)
                    copiedToken = true
                }
            }

            Button(env.signOutInProgress ? "Signing out…" : "Sign out", role: .destructive) {
                Task {
                    if await env.signOut() {
                        copiedToken = false
                        copiedAgentConfig = false
                        scheduleHealthCheck()
                    }
                }
            }
            .disabled(env.signOutInProgress)
        } else {
            SignInWithAppleButton(.signIn) { request in
                let raw = Self.randomNonceString()
                pendingAppleRawNonce = raw
                request.requestedScopes = [.email]
                request.nonce = Self.sha256Hex(raw)
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
                let identityToken = String(data: tokenData, encoding: .utf8),
                let rawNonce = pendingAppleRawNonce
            else {
                return
            }
            pendingAppleRawNonce = nil
            Task {
                await env.signInWithAppleIdentityToken(identityToken, rawNonce: rawNonce)
                scheduleHealthCheck()
            }
        case .failure:
            pendingAppleRawNonce = nil
        }
    }

    /// 32 random URL-safe characters. Used as the raw nonce for Sign in with
    /// Apple — we hash it before handing it to Apple so the raw value never
    /// leaves the device-and-our-backend conversation.
    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        result.reserveCapacity(length)
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess)
            for byte in bytes where remaining > 0 {
                let idx = Int(byte) % charset.count
                result.append(charset[idx])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

    private func copySensitiveText(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.expirationDate: Date().addingTimeInterval(2 * 60)]
        )
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }

    private var agentConfig: String {
        if ZeroZeroWidgetConstants.appleLoginEnabled, env.apiKey.isEmpty {
            return "To integrate with 00Widget, read the instructions at \(env.serverBaseURL); use that as the base URL. You'll need an authorization token, which will be available after you sign in."
        }

        if env.apiKey.isEmpty {
            return "To integrate with 00Widget, read the instructions at \(env.serverBaseURL); use that as the base URL, and enter an API key above to use as the authorization token."
        }

        return "To integrate with 00Widget, read the instructions at \(env.serverBaseURL); use that as the base URL, and use \(env.agentApiKey) as the authorization token."
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
