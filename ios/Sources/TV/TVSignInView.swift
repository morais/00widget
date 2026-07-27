import SwiftUI
import AuthenticationServices

struct TVSignInView: View {
    @EnvironmentObject var env: TVEnvironment
    @StateObject private var appleSignIn = TVAppleSignInController()

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

                if env.appleLoginInProgress || appleSignIn.isAuthorizing {
                    ProgressView(appleSignIn.isAuthorizing ? "Contacting Apple..." : "Signing in...")
                        .font(.title3)
                } else {
                    TVSignInWithAppleControl(isEnabled: true) {
                        env.clearAppleLoginError()
                        appleSignIn.start(completion: handleAppleSignIn)
                    }
                    .frame(width: 480, height: 88)
                }

                if let error = env.appleLoginError {
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }

                Text("Version \(appVersionString)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(64)
        }
    }

    private func handleAppleSignIn(
        _ result: Result<(identityToken: String, rawNonce: String), Error>
    ) {
        switch result {
        case .success(let credential):
            Task {
                await env.signInWithAppleIdentityToken(
                    credential.identityToken,
                    rawNonce: credential.rawNonce
                )
            }
        case .failure(let error):
            env.reportAppleLoginError(Self.appleAuthorizationErrorMessage(error))
        }
    }

    private static func appleAuthorizationErrorMessage(_ error: Error) -> String {
        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled {
            return "Sign in was canceled."
        }
        let nsError = error as NSError
        return "Sign in with Apple failed (\(nsError.code)): \(nsError.localizedDescription)"
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }
}
