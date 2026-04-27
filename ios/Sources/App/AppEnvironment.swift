import Foundation
import SwiftUI
import Combine

@MainActor
public final class AppEnvironment: ObservableObject {
    @Published public var serverBaseURL: String {
        didSet {
            UserDefaults.standard.set(serverBaseURL, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL)
        }
    }

    @Published public var apiKey: String
    @Published public private(set) var lastSyncAt: Date?
    @Published public private(set) var lastSyncError: String?
    @Published public private(set) var cards: [DashboardCard] = []
    @Published public private(set) var pendingActivities: [LiveActivitySession] = []
    @Published public private(set) var apnsDeviceToken: String?

    public let liveActivityController = LiveActivityController.shared
    private var apiKeyRegistrationTask: Task<Void, Never>?

    public init() {
        let defaults = UserDefaults.standard
        self.serverBaseURL = defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL) ?? ""
        self.apiKey = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? ""
        if let t = defaults.object(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.lastSyncAt) as? Date {
            self.lastSyncAt = t
        }
        self.cards = CardCache.load().cards
    }

    public func saveApiKey() {
        let previous = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? ""
        try? KeychainStore.set(apiKey, for: ZeroZeroWidgetConstants.KeychainKeys.apiKey)
        guard apiKey != previous else { return }
        clearTenantScopedState()
        scheduleCredentialRegistration()
    }

    public func apiClient() -> APIClient? {
        guard
            let url = URL(string: serverBaseURL),
            !apiKey.isEmpty
        else { return nil }
        let config = APIClientConfig(baseURL: url, apiKey: apiKey)
        return APIClient(config: config)
    }

    public func fetchCards() async {
        guard let client = apiClient() else {
            lastSyncError = "Server URL or API key not configured"
            return
        }
        do {
            let fetched = try await client.fetchCards()
            try CardCache.save(fetched)
            cards = fetched
            lastSyncAt = Date()
            lastSyncError = nil
            UserDefaults.standard.set(lastSyncAt, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.lastSyncAt)
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    public func loadCachedCards() {
        cards = CardCache.load().cards
    }

    public func generateSampleCards() {
        let samples = SampleDataFactory.makeCards()
        try? CardCache.save(samples)
        cards = samples
    }

    public func clearCache() {
        CardCache.clear()
        cards = []
    }

    private func clearTenantScopedState() {
        CardCache.clear()
        cards = []
        pendingActivities = []
        lastSyncAt = nil
        lastSyncError = nil
        UserDefaults.standard.removeObject(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.lastSyncAt)
    }

    private func scheduleCredentialRegistration() {
        apiKeyRegistrationTask?.cancel()
        guard !apiKey.isEmpty else { return }
        apiKeyRegistrationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.registerDevice()
            await self.registerPendingWidgetTokens()
        }
    }

    public func refreshPendingActivities() async {
        guard let client = apiClient() else { return }
        do {
            pendingActivities = try await client.pendingActivities()
        } catch {
            pendingActivities = []
        }
    }

    public func setAPNsDeviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        apnsDeviceToken = hex
        Task { await registerDevice() }
    }

    public func registerDevice() async {
        guard let client = apiClient() else { return }
        do {
            try await client.registerDevice(
                deviceId: DeviceRegistration.deviceId(),
                apnsDeviceToken: apnsDeviceToken,
                appVersion: DeviceRegistration.appVersion()
            )
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    /// Picks up widget push tokens that the widget extension recorded into the
    /// shared App Group file (via `WidgetPushHandler`), and registers each with
    /// the backend. Re-registration is idempotent on the server, so we don't
    /// bother tracking which tokens have been sent before.
    public func registerPendingWidgetTokens() async {
        guard let client = apiClient() else { return }
        let entries = WidgetPushTokenStore.load()
        guard !entries.isEmpty else { return }
        let deviceId = DeviceRegistration.deviceId()
        for entry in entries {
            do {
                try await client.registerWidgetPushToken(
                    deviceId: deviceId,
                    widgetKind: entry.widgetKind,
                    widgetPushToken: entry.pushToken
                )
            } catch {
                lastSyncError = "widget token register: \(error.localizedDescription)"
            }
        }
    }

    public func testConnection() async -> Bool {
        guard let client = apiClient() else { return false }
        return (try? await client.health()) == true
    }
}
