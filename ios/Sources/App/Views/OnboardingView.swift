import AuthenticationServices
import CryptoKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var healthCheckTask: Task<Void, Never>?
    @State private var copiedAgentConfig = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var confirmingSignOut = false
    @State private var showScanner = false

    /// How long the copied agent config survives on the pasteboard. The label
    /// promises this, so the expiry below and the reset timer read it here.
    private static let pasteboardLifetime: TimeInterval = 5 * 60

    private static var pasteboardLifetimeLabel: String {
        "\(Int(pasteboardLifetime / 60)) min"
    }
    // Raw nonce for the in-flight Sign in with Apple request. We hash it
    // (SHA-256) before handing it to ASAuthorizationAppleIDRequest so Apple
    // logs only the hash, and we send the raw value to the backend so it can
    // re-derive the same hash and compare against the id_token's nonce claim.
    @State private var pendingAppleRawNonce: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent config") {
                    Text(agentConfig)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(
                        copiedAgentConfig
                            ? "Copied — clipboard clears in \(Self.pasteboardLifetimeLabel)"
                            : "Copy agent config"
                    ) {
                        copySensitiveText(agentConfig)
                        copiedAgentConfig = true
                        copyResetTask?.cancel()
                        copyResetTask = Task {
                            try? await Task.sleep(for: .seconds(Self.pasteboardLifetime))
                            guard !Task.isCancelled else { return }
                            copiedAgentConfig = false
                        }
                    }
                }

                Section("Server") {
                    // The URL is only worth a row when the user can change it.
                    // Under Apple login it is fixed at build time, and the
                    // agent config above already names it.
                    if !ZeroZeroWidgetConstants.appleLoginEnabled {
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
                    if env.connectionHealth == .failed {
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

                // Above Sharing and outside the ZW_SHARING_ENABLED gate on
                // purpose: scanning a link needs no account, and for a guest
                // this is the only section on the screen that does anything.
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan a shared code", systemImage: "qrcode.viewfinder")
                    }

                    ForEach(env.guestLinks) { link in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.title ?? "Shared item")
                            Text(link.hasExpired
                                 ? "Expired"
                                 : link.expiresAt.map { "Until \($0.formatted(date: .abbreviated, time: .shortened))" }
                                    ?? "Read-only")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            env.removeGuestLink(token: env.guestLinks[index].token)
                        }
                    }
                } header: {
                    Text("Shared with you")
                } footer: {
                    if env.guestLinks.isEmpty {
                        Text("Scan a code someone shows you to follow one of their cards or Live Activities. You do not need an account.")
                    } else {
                        Text("Swipe to remove. Removing a link only affects this device.")
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

                // Reached from Settings rather than the tab bar: a fourth tab
                // changes the tab bar in every screenshot and costs a slot on
                // the surface users actually navigate.
                if ZeroZeroWidgetConstants.debugToolsEnabled {
                    Section("Developer") {
                        NavigationLink("Debug tools") {
                            DeveloperView()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showScanner) {
                GuestLinkScannerSheet().environmentObject(env)
            }
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

            Button(env.signOutInProgress ? "Signing out…" : "Sign out", role: .destructive) {
                confirmingSignOut = true
            }
            .disabled(env.signOutInProgress)
            .confirmationDialog(
                "Sign out?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    Task {
                        if await env.signOut() {
                            copiedAgentConfig = false
                            scheduleHealthCheck()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Sign out revokes the whole session, agent publisher token
                // included, so every agent stops publishing until it gets the
                // new token from Agent config.
                Text("This revokes your agent token. Any agent publishing cards will stop working until you sign in again and give it the new token.")
            }
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
            options: [.expirationDate: Date().addingTimeInterval(Self.pasteboardLifetime)]
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
