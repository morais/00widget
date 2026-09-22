import AuthenticationServices
import CryptoKit
import SwiftUI

struct DeviceAuthorizationApprovalView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let userCode: String

    @State private var pendingAppleRawNonce: String?
    @State private var connected = false

    var body: some View {
        NavigationStack {
            // A consent screen has to show the sentence saying what is being
            // granted. At a `.medium` detent this column is about 40 points
            // too tall at standard type, and a `VStack` that overflows does
            // not scroll — it truncates, so the sentence arrived as "This lets
            // the headset read your dashboard…" with the Connect button still
            // sitting under it. Nothing in a build or the suite sees that.
            //
            // So the sheet takes the full height and the column is centred in
            // it; at accessibility sizes the column outgrows even that and the
            // scroll view carries the rest rather than clipping it.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                        Image(systemName: connected ? "checkmark.circle.fill" : "visionpro")
                            .font(.system(size: 52))
                            .foregroundStyle(connected ? Color.green : Color.accentColor)
                            .accessibilityHidden(true)

                        VStack(spacing: 8) {
                            Text(connected ? "Headset connected" : "Connect Horizon OS?")
                                .font(.title2.bold())
                            Text(userCode)
                                .font(.title3.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                                .accessibilityLabel("Connection code \(userCode)")
                        }

                        if connected {
                            Text("Return to your headset to finish signing in.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                            Button("Done") { dismiss() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        } else if env.apiKey.isEmpty {
                            Text("Sign in with the Apple Account you use for 00Widget. After signing in, you’ll confirm this headset separately.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)

                            SignInWithAppleButton(.signIn) { request in
                                let raw = Self.randomNonceString()
                                pendingAppleRawNonce = raw
                                request.requestedScopes = [.email]
                                request.nonce = Self.sha256Hex(raw)
                            } onCompletion: { result in
                                handleAppleSignIn(result)
                            }
                            .frame(height: 48)
                            .disabled(env.appleLoginInProgress)
                        } else {
                            if let email = env.appleLoginEmail {
                                Text("Signed in as \(email)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            // Word for word what the browser fallback says in
                            // `renderDeviceApproval`; the two are one consent
                            // string for one grant. The account half is not
                            // decoration: the credential is minted `kind:
                            // "app"`, which is the whole gate on the app-only
                            // account routes, deleting the account included.
                            //
                            // It deliberately claims no limit. "It cannot
                            // publish widgets" was true of the scopes and
                            // false in effect: agent-token rotation is one of
                            // those ungated routes, and it answers with a
                            // fresh producer token in plaintext. One call and
                            // the headset holds `publish`.
                            Text("This headset will be able to read your dashboard, run its safe actions, and manage your account — including your connected agents and deleting the account.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)

                            Button {
                                Task {
                                    connected = await env.approveDeviceAuthorization(userCode: userCode)
                                }
                            } label: {
                                if env.deviceAuthorizationInProgress {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Connect headset")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            // Matches the 48pt Sign in with Apple button that
                            // fills this same slot in the signed-out branch;
                            // at the default size it read as a thin strip
                            // beside everything else on the sheet.
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(env.deviceAuthorizationInProgress)
                        }

                        if let error = env.appleLoginError ?? env.deviceAuthorizationError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("00Widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !connected {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(env.deviceAuthorizationInProgress)
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8),
                let rawNonce = pendingAppleRawNonce
            else { return }
            pendingAppleRawNonce = nil
            Task {
                _ = await env.signInWithAppleIdentityToken(identityToken, rawNonce: rawNonce)
            }
        case .failure(let error):
            pendingAppleRawNonce = nil
            if (error as? ASAuthorizationError)?.code != .canceled {
                env.reportDeviceAuthorizationError(error.localizedDescription)
            }
        }
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        result.reserveCapacity(length)
        while result.count < length {
            var bytes = [UInt8](repeating: 0, count: 16)
            precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
            for byte in bytes where result.count < length {
                result.append(charset[Int(byte) % charset.count])
            }
        }
        return result
    }

    private static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
