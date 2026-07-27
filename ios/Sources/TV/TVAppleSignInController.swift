import AuthenticationServices
import CryptoKit
import Security
import SwiftUI
import UIKit

@MainActor
final class TVAppleSignInController: NSObject, ObservableObject {
    @Published private(set) var isAuthorizing = false

    private var authorizationController: ASAuthorizationController?
    private var completion: ((Result<(identityToken: String, rawNonce: String), Error>) -> Void)?
    private var pendingRawNonce: String?

    func start(
        completion: @escaping (Result<(identityToken: String, rawNonce: String), Error>) -> Void
    ) {
        guard !isAuthorizing else { return }

        let rawNonce = Self.randomNonceString()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = Self.sha256Hex(rawNonce)

        self.completion = completion
        pendingRawNonce = rawNonce
        isAuthorizing = true

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        authorizationController = controller
        controller.performRequests()
    }

    private func finish(
        _ result: Result<(identityToken: String, rawNonce: String), Error>
    ) {
        let completion = completion
        self.completion = nil
        pendingRawNonce = nil
        authorizationController = nil
        isAuthorizing = false
        completion?(result)
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
                result.append(charset[Int(byte) % charset.count])
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

extension TVAppleSignInController: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let identityToken = String(data: tokenData, encoding: .utf8),
            let rawNonce = pendingRawNonce
        else {
            finish(.failure(TVAppleSignInError.missingIdentityToken))
            return
        }
        finish(.success((identityToken, rawNonce)))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }
}

extension TVAppleSignInController: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
                return window
            }
        }
        guard let scene = scenes.first else {
            preconditionFailure("Apple authorization requested without an active window scene")
        }
        return ASPresentationAnchor(windowScene: scene)
    }
}

private enum TVAppleSignInError: LocalizedError {
    case missingIdentityToken

    var errorDescription: String? {
        "Apple completed sign-in without returning a usable identity token. Please try again."
    }
}

struct TVSignInWithAppleControl: UIViewRepresentable {
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .white)
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.activate),
            for: .primaryActionTriggered
        )
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        uiView.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func activate() {
            action()
        }
    }
}
