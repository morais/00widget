import SwiftUI
import AuthenticationServices

struct TVSignInView: View {
    @EnvironmentObject var env: TVEnvironment

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
                        request.requestedScopes = [.email]
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
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                return
            }
            Task { await env.signInWithAppleIdentityToken(identityToken) }
        case .failure:
            break
        }
    }
}
