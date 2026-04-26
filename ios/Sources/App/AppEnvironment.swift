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
        try? KeychainStore.set(apiKey, for: ZeroZeroWidgetConstants.KeychainKeys.apiKey)
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

    public func testConnection() async -> Bool {
        guard let client = apiClient() else { return false }
        return (try? await client.health()) == true
    }
}
