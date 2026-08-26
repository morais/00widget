import Foundation
import SwiftUI

@MainActor
final class TVEnvironment: ObservableObject {
    @Published var apiKey: String
    @Published private(set) var appleLoginEmail: String?
    @Published private(set) var appleLoginError: String?
    @Published private(set) var appleLoginInProgress = false
    @Published private(set) var signOutInProgress = false
    @Published private(set) var accountDeletionInProgress = false
    @Published private(set) var cards: [DashboardCard] = []
    @Published private(set) var sharedCards: [DashboardCard] = []
    @Published private(set) var liveActivities: [LiveActivitySession] = []
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var isRefreshing = false

    let serverBaseURL: String

    private var autoRefreshTask: Task<Void, Never>?

    init() {
        #if ZW_SCREENSHOTS
        self.serverBaseURL = ZeroZeroWidgetConstants.defaultServerBaseURL
        self.apiKey = "screenshot"
        self.appleLoginEmail = nil
        let screenshotSection = ProcessInfo.processInfo.arguments
            .drop(while: { $0 != "--screenshot-section" })
            .dropFirst()
            .first
        let samples = SampleDataFactory.makeCards()
        if screenshotSection == "activities" {
            self.cards = []
        } else if screenshotSection == "insights" {
            self.cards = Array(samples.suffix(3))
        } else {
            self.cards = samples
        }
        self.liveActivities = screenshotSection == "widgets"
            ? []
            : [SampleDataFactory.makeLiveActivitySession()]
        SharedSettings.setHideSampleIndicators(true)
        #else
        let defaults = UserDefaults.standard
        self.serverBaseURL = ZeroZeroWidgetConstants.defaultServerBaseURL
        self.apiKey = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? ""
        self.appleLoginEmail = defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
        self.cards = CardCache.load().cards
        #endif
    }

    var isSignedIn: Bool { !apiKey.isEmpty }

    func apiClient() -> APIClient? {
        guard
            let url = APIClientConfig.validatedBaseURL(from: serverBaseURL),
            !apiKey.isEmpty
        else { return nil }
        let config = APIClientConfig(baseURL: url, apiKey: apiKey)
        return APIClient(config: config)
    }

    func startupSync() async {
        #if ZW_SCREENSHOTS
        return
        #else
        await refreshAccount()
        await fetchCards()
        startAutoRefresh()
        #endif
    }

    func signInWithAppleIdentityToken(_ identityToken: String, rawNonce: String) async {
        guard let url = APIClientConfig.validatedBaseURL(from: serverBaseURL) else {
            appleLoginError = "Server URL must use HTTPS"
            return
        }
        appleLoginInProgress = true
        appleLoginError = nil
        defer { appleLoginInProgress = false }
        do {
            let response = try await APIClient.createTokenFromApple(
                baseURL: url,
                identityToken: identityToken,
                rawNonce: rawNonce,
                label: appVersion(),
                deviceId: SharedSettings.deviceId()
            )
            apiKey = response.token
            KeychainStore.deleteAppOnly(ZeroZeroWidgetConstants.KeychainKeys.appCredential)
            try KeychainStore.set(apiKey, for: ZeroZeroWidgetConstants.KeychainKeys.apiKey)
            try KeychainStore.setAppOnly(
                response.appCredential,
                for: ZeroZeroWidgetConstants.KeychainKeys.appCredential
            )
            appleLoginEmail = response.tenant.ownerEmail
            UserDefaults.standard.set(appleLoginEmail, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
            await fetchCards()
            startAutoRefresh()
        } catch {
            appleLoginError = error.localizedDescription
        }
    }

    /// See `AppEnvironment.refreshAccount`: the credentials survive an
    /// uninstall in the Keychain and the email did not, so the server is asked
    /// again rather than the address being lost until the next sign-in.
    func refreshAccount() async {
        guard !apiKey.isEmpty, let client = confirmedActionClient() else { return }
        guard let response = try? await client.fetchAccount() else { return }
        guard let email = response.account.ownerEmail, !email.isEmpty else { return }
        appleLoginEmail = email
        UserDefaults.standard.set(
            email,
            forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail
        )
    }

    func clearAppleLoginError() {
        appleLoginError = nil
    }

    func confirmedActionClient() -> APIClient? {
        guard
            let url = APIClientConfig.validatedBaseURL(from: serverBaseURL),
            let credential = KeychainStore.getAppOnly(ZeroZeroWidgetConstants.KeychainKeys.appCredential),
            !credential.isEmpty
        else { return nil }
        return APIClient(config: APIClientConfig(baseURL: url, apiKey: credential))
    }

    func reportAppleLoginError(_ message: String) {
        appleLoginError = message
    }

    func signOut() async -> Bool {
        signOutInProgress = true
        appleLoginError = nil
        defer { signOutInProgress = false }
        if let client = confirmedActionClient() {
            do {
                try await client.revokeCurrentCredential()
                clearLocalCredentials()
                return true
            } catch let error as APIClientError where error.status == 401 {
                // Fall through to the publisher token when the private half
                // of the credential pair was already revoked.
            } catch {
                appleLoginError = "Could not revoke this session: \(error.localizedDescription)"
                return false
            }
        }
        do {
            if let client = apiClient() {
                try await client.revokeCurrentCredential()
            }
        } catch {
            appleLoginError = "Could not revoke this session: \(error.localizedDescription)"
            return false
        }

        clearLocalCredentials()
        return true
    }

    /// Same act as the iOS app's, and deliberately the same endpoint: Apple
    /// requires deletion wherever the account can be created, and this app
    /// signs in with Apple too. The app credential is the only one the route
    /// accepts, so a device that has lost it says so rather than clearing up
    /// locally and calling the account gone.
    func deleteAccount() async -> Bool {
        accountDeletionInProgress = true
        appleLoginError = nil
        defer { accountDeletionInProgress = false }

        guard let client = confirmedActionClient() else {
            appleLoginError = "This device isn't authorized for that. Sign out and sign in again."
            return false
        }
        do {
            try await client.deleteAccount()
        } catch let error as APIClientError where error.status == 401 || error.status == 403 {
            appleLoginError = "This device isn't authorized for that. Sign out and sign in again."
            return false
        } catch {
            appleLoginError = "Could not delete the account: \(error.localizedDescription)"
            return false
        }

        clearLocalCredentials()
        return true
    }

    private func clearLocalCredentials() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        apiKey = ""
        appleLoginEmail = nil
        appleLoginError = nil
        KeychainStore.delete(ZeroZeroWidgetConstants.KeychainKeys.apiKey)
        KeychainStore.deleteAppOnly(ZeroZeroWidgetConstants.KeychainKeys.appCredential)
        UserDefaults.standard.removeObject(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
        CardCache.clear()
        cards = []
        sharedCards = []
        liveActivities = []
        lastSyncAt = nil
        lastSyncError = nil
    }

    func fetchCards() async {
        guard let client = apiClient() else {
            lastSyncError = isSignedIn ? "Server URL invalid" : nil
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let dashboard = try await client.fetchDashboard()
            cards = dashboard.cards
            liveActivities = dashboard.activities
            try? CardCache.save(dashboard.cards)
            lastSyncAt = Date()
            lastSyncError = nil
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        guard isSignedIn else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.fetchCards()
            }
        }
    }

    private func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "tvOS \(marketing) (\(build))"
    }
}
