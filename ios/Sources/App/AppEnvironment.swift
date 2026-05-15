import Foundation
import SwiftUI
import Combine

public enum ConnectionHealthStatus: Equatable {
    case unknown
    case notConfigured
    case checking
    case ok
    case failed
}

@MainActor
public final class AppEnvironment: ObservableObject {
    @Published public var serverBaseURL: String {
        didSet {
            UserDefaults.standard.set(serverBaseURL, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL)
        }
    }

    @Published public var apiKey: String
    @Published public private(set) var appleLoginEmail: String?
    @Published public private(set) var appleLoginError: String?
    @Published public private(set) var appleLoginInProgress = false
    @Published public private(set) var lastSyncAt: Date?
    @Published public private(set) var lastSyncError: String?
    @Published public private(set) var cards: [DashboardCard] = []
    @Published public private(set) var pendingActivities: [LiveActivitySession] = []
    @Published public private(set) var sharedCards: [DashboardCard] = []
    #if ZW_SHARING_ENABLED
    @Published public private(set) var incomingShares: [ShareRecord] = []
    @Published public private(set) var outgoingShares: [ShareRecord] = []
    @Published public private(set) var sharingDisabledByServer: Bool = false
    #endif
    @Published public private(set) var apnsDeviceToken: String?
    @Published public private(set) var notificationsAuthorized = false
    @Published public private(set) var notificationsDenied = false
    @Published public private(set) var connectionHealth: ConnectionHealthStatus = .unknown
    @Published public var showActivitiesTab: Bool {
        didSet {
            UserDefaults.standard.set(showActivitiesTab, forKey: "zw.showActivitiesTab")
        }
    }

    public let liveActivityController = LiveActivityController.shared
    private var apiKeyRegistrationTask: Task<Void, Never>?
    private var lastForegroundFetchAt: Date?

    public init() {
        let defaults = UserDefaults.standard
        let configuredServerBaseURL = ZeroZeroWidgetConstants.defaultServerBaseURL
        self.serverBaseURL = ZeroZeroWidgetConstants.appleLoginEnabled
            ? configuredServerBaseURL
            : defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL) ?? configuredServerBaseURL
        self.apiKey = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? ""
        self.appleLoginEmail = defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
        if let t = defaults.object(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.lastSyncAt) as? Date {
            self.lastSyncAt = t
        }
        self.showActivitiesTab = defaults.object(forKey: "zw.showActivitiesTab") as? Bool ?? true
        self.cards = CardCache.load().cards
    }

    public func saveApiKey() {
        let previous = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? ""
        try? KeychainStore.set(apiKey, for: ZeroZeroWidgetConstants.KeychainKeys.apiKey)
        guard apiKey != previous else { return }
        clearTenantScopedState()
        scheduleCredentialRegistration()
    }

    public func signInWithAppleIdentityToken(_ identityToken: String, rawNonce: String) async {
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
                label: DeviceRegistration.appVersion()
            )
            apiKey = response.token
            appleLoginEmail = response.tenant.ownerEmail
            UserDefaults.standard.set(response.tenant.ownerEmail, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
            saveApiKey()
            await refreshConnectionHealth()
        } catch {
            appleLoginError = error.localizedDescription
        }
    }

    public func clearApiKey() {
        apiKey = ""
        appleLoginEmail = nil
        appleLoginError = nil
        UserDefaults.standard.removeObject(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
        saveApiKey()
    }

    public func apiClient() -> APIClient? {
        guard
            let url = APIClientConfig.validatedBaseURL(from: serverBaseURL),
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
            #if ZW_SHARING_ENABLED
            let result = try await client.fetchCardsIncludingShared()
            cards = result.own
            sharedCards = result.shared
            try CardCache.save(result.own)
            #else
            let fetched = try await client.fetchCards()
            cards = fetched
            sharedCards = []
            try CardCache.save(fetched)
            #endif
            lastSyncAt = Date()
            lastSyncError = nil
            UserDefaults.standard.set(lastSyncAt, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.lastSyncAt)
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    #if ZW_SHARING_ENABLED
    public func refreshShares() async {
        guard let client = apiClient() else { return }
        do {
            async let outgoing = client.listOutgoingShares()
            async let incoming = client.listIncomingShares()
            outgoingShares = try await outgoing
            incomingShares = try await incoming
            sharingDisabledByServer = false
        } catch let error as APIClientError where error.status == 503 {
            sharingDisabledByServer = true
            outgoingShares = []
            incomingShares = []
        } catch {
            // leave previous state intact; surface via lastSyncError so the
            // settings screen can show it
            lastSyncError = "shares: \(error.localizedDescription)"
        }
    }

    public func createShare(
        recipientEmail: String,
        resourceKind: ShareResourceKind,
        resourceId: String
    ) async throws {
        guard let client = apiClient() else {
            throw APIClientError(status: 0, message: "not configured")
        }
        _ = try await client.createShare(
            recipientEmail: recipientEmail,
            resourceKind: resourceKind,
            resourceId: resourceId
        )
        await refreshShares()
    }

    public func acceptShare(id: String) async {
        guard let client = apiClient() else { return }
        try? await client.acceptShare(id: id)
        await refreshShares()
        await fetchCards()
    }

    public func declineShare(id: String) async {
        guard let client = apiClient() else { return }
        try? await client.declineShare(id: id)
        await refreshShares()
    }

    public func revokeShare(id: String) async {
        guard let client = apiClient() else { return }
        try? await client.revokeShare(id: id)
        await refreshShares()
        await fetchCards()
    }
    #endif

    public func loadCachedCards() {
        cards = CardCache.load().cards
    }

    public func syncAfterForeground() async {
        loadCachedCards()
        let now = Date()
        if let lastForegroundFetchAt, now.timeIntervalSince(lastForegroundFetchAt) < 30 {
            return
        }
        lastForegroundFetchAt = now
        await fetchCards()
    }

    public func startupSync() async {
        await requestNotificationAuthorization()
        if notificationsAuthorized, apiClient() != nil {
            DeviceRegistration.registerForRemoteNotifications()
        }
        await refreshConnectionHealth()
        await registerDevice()
        await registerPendingWidgetTokens()
        await fetchCards()
        await startPendingActivities()
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
        sharedCards = []
        pendingActivities = []
        #if ZW_SHARING_ENABLED
        incomingShares = []
        outgoingShares = []
        sharingDisabledByServer = false
        #endif
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
            await self.refreshConnectionHealth()
            if self.notificationsAuthorized {
                DeviceRegistration.registerForRemoteNotifications()
            }
            await self.registerDevice()
            await self.registerPendingWidgetTokens()
            await self.fetchCards()
            await self.startPendingActivities()
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

    public func startPendingActivities() async {
        await refreshPendingActivities()
        let activities = pendingActivities
        guard !activities.isEmpty else { return }
        for activity in activities where !liveActivityController.activeIds.contains(activity.externalActivityId) {
            do {
                try await liveActivityController.start(activity)
            } catch {
                lastSyncError = "live activity start: \(error.localizedDescription)"
            }
        }
        await refreshPendingActivities()
    }

    public func setAPNsDeviceToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        apnsDeviceToken = hex
        Task { await registerDevice() }
    }

    public func refreshNotificationAuthorization() async {
        notificationsAuthorized = await DeviceRegistration.notificationsAuthorized()
        notificationsDenied = await DeviceRegistration.notificationsDenied()
    }

    @discardableResult
    public func requestNotificationAuthorization() async -> Bool {
        notificationsAuthorized = await DeviceRegistration.requestNotificationAuthorization()
        notificationsDenied = await DeviceRegistration.notificationsDenied()
        if notificationsAuthorized {
            DeviceRegistration.registerForRemoteNotifications()
        }
        return notificationsAuthorized
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

    @discardableResult
    public func refreshConnectionHealth() async -> Bool {
        guard let client = apiClient() else {
            connectionHealth = .notConfigured
            return false
        }
        connectionHealth = .checking
        let ok = (try? await client.fetchCards()) != nil
        connectionHealth = ok ? .ok : .failed
        return ok
    }

    public func testConnection() async -> Bool {
        await refreshConnectionHealth()
    }
}
