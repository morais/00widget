import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

struct TVSignInView: View {
    @EnvironmentObject var env: TVEnvironment
    @State private var pendingAppleRawNonce: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(white: 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.tint)
                    Text("00Widget")
                        .font(.system(size: 64, weight: .bold))
                    Text("Widgets for all your agents.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if env.appleLoginInProgress {
                    ProgressView("Signing in...")
                        .font(.title3)
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        let raw = Self.randomNonceString()
                        pendingAppleRawNonce = raw
                        request.requestedScopes = [.email]
                        request.nonce = Self.sha256Hex(raw)
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(width: 480, height: 88)
                }

                if let error = env.appleLoginError {
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }
            }
            .padding(64)
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
            Task { await env.signInWithAppleIdentityToken(identityToken, rawNonce: rawNonce) }
        case .failure:
            pendingAppleRawNonce = nil
        }
    }

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
}
