import Foundation
import SwiftUI

@MainActor
final class TVEnvironment: ObservableObject {
    @Published var apiKey: String
    @Published private(set) var appleLoginEmail: String?
    @Published private(set) var appleLoginError: String?
    @Published private(set) var appleLoginInProgress = false
    @Published private(set) var cards: [DashboardCard] = []
    @Published private(set) var sharedCards: [DashboardCard] = []
    @Published private(set) var liveActivities: [LiveActivitySession] = []
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var isRefreshing = false

    let serverBaseURL: String

    private var autoRefreshTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        self.serverBaseURL = ZeroZeroWidgetConstants.defaultServerBaseURL
        self.apiKey = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? ""
        self.appleLoginEmail = defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
        self.cards = CardCache.load().cards
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
        await fetchCards()
        startAutoRefresh()
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
                label: appVersion()
            )
            apiKey = response.token
            appleLoginEmail = response.tenant.ownerEmail
            try? KeychainStore.set(apiKey, for: ZeroZeroWidgetConstants.KeychainKeys.apiKey)
            UserDefaults.standard.set(appleLoginEmail, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
            await fetchCards()
            startAutoRefresh()
        } catch {
            appleLoginError = error.localizedDescription
        }
    }

    func clearAppleLoginError() {
        appleLoginError = nil
    }

    func reportAppleLoginError(_ message: String) {
        appleLoginError = message
    }

    func signOut() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        apiKey = ""
        appleLoginEmail = nil
        appleLoginError = nil
        KeychainStore.delete(ZeroZeroWidgetConstants.KeychainKeys.apiKey)
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
