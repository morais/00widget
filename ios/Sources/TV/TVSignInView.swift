import SwiftUI
import AuthenticationServices

struct TVSignInView: View {
    @EnvironmentObject var env: TVEnvironment
    @StateObject private var appleSignIn = TVAppleSignInController()

    var body: some View {
        ZStack {
            // The launch image is the mark and the wordmark on this exact
            // radial navy, so continuing it here lets the launch resolve into
            // the first screen instead of cutting to an unrelated black. Both
            // stops are generated into the catalog from the same constants the
            // artwork is drawn with — see scripts/generate-brand-assets.py.
            RadialGradient(
                colors: [Color("BackdropCenter"), Color("BackdropEdge")],
                center: .center,
                startRadius: 0,
                // tvOS lays out in a fixed 1920x1080, so the distance from the
                // centre to a corner is a constant.
                endRadius: 1102
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                VStack(spacing: 24) {
                    Image("Mark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 260)
                    VStack(spacing: 10) {
                        Text("00Widget")
                            .font(.system(size: 64, weight: .bold))
                        Text("Widgets for all your agents.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
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
                    // See the note in `TVDashboardView.freshness`: tertiary is
                    // about 2.5:1 on this backdrop. At 23pt — the platform
                    // floor — this was the smallest text in the app at its
                    // lowest contrast.
                    .foregroundStyle(.secondary)
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
