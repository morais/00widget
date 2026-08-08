import Foundation
import SwiftUI
import Combine
import WidgetKit
import os

public enum ConnectionHealthStatus: Equatable {
    case unknown
    case notConfigured
    case checking
    case ok
    case failed
}

@MainActor
public final class AppEnvironment: ObservableObject {
    private static let widgetPushLog = Logger(
        subsystem: "com.example.zerozerowidget",
        category: "WidgetPush"
    )
    private static let widgetTokenRetryDelaysNanoseconds: [UInt64] = [
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
        16_000_000_000
    ]

    @Published public var serverBaseURL: String {
        didSet {
            UserDefaults.standard.set(serverBaseURL, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL)
            if SharedSettings.serverBaseURL != serverBaseURL {
                SharedSettings.setServerBaseURL(serverBaseURL)
                WidgetPushTokenStore.invalidateRegistration()
                scheduleCredentialRegistration()
            }
        }
    }

    @Published public var apiKey: String
    @Published public private(set) var publisherCredential: String
    @Published public private(set) var appleLoginEmail: String?
    @Published public private(set) var appleLoginError: String?
    @Published public private(set) var appleLoginInProgress = false
    @Published public private(set) var signOutInProgress = false
    @Published public private(set) var lastSyncAt: Date?
    @Published public private(set) var lastSyncError: String?
    @Published public private(set) var cards: [DashboardCard] = []
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

    /// nil until WidgetKit has answered once, so the setup hint never flashes
    /// on a device that does have widgets installed.
    @Published public private(set) var installedWidgetCount: Int?
    @Published public var didDismissWidgetSetupHint: Bool {
        didSet {
            UserDefaults.standard.set(didDismissWidgetSetupHint, forKey: "zw.didDismissWidgetSetupHint")
        }
    }

    public let liveActivityController = LiveActivityController.shared
    private var apiKeyRegistrationTask: Task<Void, Never>?
    private var widgetTokenRetryTask: Task<Void, Never>?
    private var lastForegroundFetchAt: Date?

    public init() {
        let defaults = UserDefaults.standard
        let configuredServerBaseURL = ZeroZeroWidgetConstants.defaultServerBaseURL
        self.serverBaseURL = ZeroZeroWidgetConstants.appleLoginEnabled
            ? configuredServerBaseURL
            : defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL) ?? configuredServerBaseURL
        self.apiKey = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? ""
        self.publisherCredential = KeychainStore.getAppOnly(
            ZeroZeroWidgetConstants.KeychainKeys.publisherCredential
        ) ?? ""
        self.appleLoginEmail = defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
        if let t = defaults.object(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.lastSyncAt) as? Date {
            self.lastSyncAt = t
        }
        self.showActivitiesTab = defaults.object(forKey: "zw.showActivitiesTab") as? Bool ?? true
        self.didDismissWidgetSetupHint = defaults.bool(forKey: "zw.didDismissWidgetSetupHint")
        self.cards = CardCache.load().cards
        SharedSettings.setServerBaseURL(serverBaseURL)
        _ = SharedSettings.deviceId()
    }

    public func saveApiKey() {
        let previous = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? ""
        try? KeychainStore.set(apiKey, for: ZeroZeroWidgetConstants.KeychainKeys.apiKey)
        if apiKey != previous {
            KeychainStore.deleteAppOnly(ZeroZeroWidgetConstants.KeychainKeys.appCredential)
            KeychainStore.deleteAppOnly(ZeroZeroWidgetConstants.KeychainKeys.publisherCredential)
            publisherCredential = ""
            clearTenantScopedState()
            WidgetPushTokenStore.invalidateRegistration()
        }
        liveActivityController.credentialsDidChange()
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
                label: DeviceRegistration.appVersion(),
                deviceId: DeviceRegistration.deviceId()
            )
            apiKey = response.token
            saveApiKey()
            try KeychainStore.setAppOnly(
                response.appCredential,
                for: ZeroZeroWidgetConstants.KeychainKeys.appCredential
            )
            let agentCredential = response.publisherCredential ?? response.token
            try KeychainStore.setAppOnly(
                agentCredential,
                for: ZeroZeroWidgetConstants.KeychainKeys.publisherCredential
            )
            publisherCredential = agentCredential
            appleLoginEmail = response.tenant.ownerEmail
            UserDefaults.standard.set(response.tenant.ownerEmail, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
            await refreshConnectionHealth()
        } catch {
            appleLoginError = error.localizedDescription
        }
    }

    public func signOut() async -> Bool {
        signOutInProgress = true
        appleLoginError = nil
        defer { signOutInProgress = false }

        if let client = confirmedActionClient() {
            do {
                try await client.revokeCurrentCredential()
                clearLocalCredentials()
                return true
            } catch let error as APIClientError where error.status == 401 {
                // The app credential may have been revoked independently;
                // fall back to the paired publisher token for cleanup.
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

    private func clearLocalCredentials() {
        apiKey = ""
        appleLoginEmail = nil
        appleLoginError = nil
        KeychainStore.deleteAppOnly(ZeroZeroWidgetConstants.KeychainKeys.appCredential)
        KeychainStore.deleteAppOnly(ZeroZeroWidgetConstants.KeychainKeys.publisherCredential)
        publisherCredential = ""
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

    public func confirmedActionClient() -> APIClient? {
        guard
            let url = APIClientConfig.validatedBaseURL(from: serverBaseURL),
            let credential = KeychainStore.getAppOnly(ZeroZeroWidgetConstants.KeychainKeys.appCredential),
            !credential.isEmpty
        else { return nil }
        return APIClient(config: APIClientConfig(baseURL: url, apiKey: credential))
    }

    /// Sharing and confirmed actions run on the app credential, which only a
    /// Sign in with Apple round trip mints — a session predating app
    /// credentials has a working API key and no app credential.
    public static let reauthorizationMessage =
        "This device isn't authorized for that. Sign out and sign in again in Settings."

    public var agentApiKey: String {
        publisherCredential.isEmpty ? apiKey : publisherCredential
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
            reloadWidgetTimelines()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    #if ZW_SHARING_ENABLED
    public func refreshShares() async {
        guard let client = confirmedActionClient() else { return }
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
        guard let client = confirmedActionClient() else {
            throw APIClientError(status: 0, message: Self.reauthorizationMessage)
        }
        _ = try await client.createShare(
            recipientEmail: recipientEmail,
            resourceKind: resourceKind,
            resourceId: resourceId
        )
        await refreshShares()
    }

    public func acceptShare(id: String) async {
        guard let client = confirmedActionClient() else { return }
        try? await client.acceptShare(id: id)
        await refreshShares()
        await fetchCards()
    }

    public func declineShare(id: String) async {
        guard let client = confirmedActionClient() else { return }
        try? await client.declineShare(id: id)
        await refreshShares()
    }

    public func revokeShare(id: String) async {
        guard let client = confirmedActionClient() else { return }
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
        // Runs ahead of the throttle: coming back from the Home Screen is
        // exactly when a widget has just been added, and the hint should go
        // away on its own rather than waiting out the fetch interval.
        await refreshInstalledWidgetCount()
        // APNs can accept an end event that the device never applies. Compare
        // ActivityKit's local state with the server on every foreground so an
        // orphan does not remain on the Lock Screen indefinitely.
        await liveActivityController.reconcileWithServer()
        let now = Date()
        if let lastForegroundFetchAt, now.timeIntervalSince(lastForegroundFetchAt) < 30 {
            return
        }
        lastForegroundFetchAt = now
        // A registration attempt can fail while the extension or app has no
        // network. The durable snapshot stays unacknowledged, so each later
        // foreground is a natural retry point without polling in background.
        await registerPendingWidgetTokens()
        await fetchCards()
    }

    public func startupSync() async {
        liveActivityController.credentialsDidChange()
        await liveActivityController.reconcileWithServer()
        // Only ask once there is an account to receive updates for. Prompting
        // on first launch asks before the user knows what the app does, and a
        // denial can only be undone in System Settings.
        if apiKey.isEmpty {
            await refreshNotificationAuthorization()
        } else {
            await requestNotificationAuthorization()
        }
        await refreshConnectionHealth()
        await registerDevice()
        await registerPendingWidgetTokens()
        await refreshInstalledWidgetCount()
        await fetchCards()
    }

    public func refreshInstalledWidgetCount() async {
        guard let configurations = try? await WidgetCenter.shared.currentConfigurations() else { return }
        installedWidgetCount = configurations
            .filter { ZeroZeroWidgetConstants.WidgetKinds.all.contains($0.kind) }
            .count
    }

    public var shouldShowWidgetSetupHint: Bool {
        installedWidgetCount == 0 && !didDismissWidgetSetupHint
    }

    public func generateSampleCards() {
        let samples = SampleDataFactory.makeCards()
        try? CardCache.save(samples)
        cards = samples
        reloadWidgetTimelines()
    }

    public var hasSampleCards: Bool {
        cards.contains { $0.isSample }
    }

    /// Samples only ever live in the App Group cache, so removing them is a
    /// local edit. Production builds ship without the Debug tab, and a signed
    /// out user never reaches a successful fetch, so this is the only way back
    /// out of the sample state for them.
    public func clearSampleCards() {
        let remaining = cards.filter { !$0.isSample }
        if remaining.isEmpty {
            CardCache.clear()
        } else {
            try? CardCache.save(remaining)
        }
        cards = remaining
        reloadWidgetTimelines()
    }

    public func clearCache() {
        CardCache.clear()
        cards = []
        reloadWidgetTimelines()
    }

    private func clearTenantScopedState() {
        CardCache.clear()
        cards = []
        sharedCards = []
        #if ZW_SHARING_ENABLED
        incomingShares = []
        outgoingShares = []
        sharingDisabledByServer = false
        #endif
        lastSyncAt = nil
        lastSyncError = nil
        UserDefaults.standard.removeObject(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.lastSyncAt)
        reloadWidgetTimelines()
    }

    func reloadWidgetTimelines() {
        for kind in ZeroZeroWidgetConstants.WidgetKinds.all {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    private func scheduleCredentialRegistration() {
        apiKeyRegistrationTask?.cancel()
        guard !apiKey.isEmpty else { return }
        apiKeyRegistrationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.refreshConnectionHealth()
            // Signing in (or pasting a key) is the moment the prompt makes
            // sense. Already-decided authorization returns without prompting,
            // so this stays a no-op on every later credential change.
            await self.requestNotificationAuthorization()
            await self.registerDevice()
            await self.registerPendingWidgetTokens()
            await self.fetchCards()
        }
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

    /// Reconciles WidgetKit's current token/configurations with the durable
    /// extension snapshot, then retries server registration when needed.
    public func registerPendingWidgetTokens() async {
        let needsRetry = await reconcileWidgetPushToken()
        if needsRetry {
            scheduleWidgetTokenRetries()
        } else {
            widgetTokenRetryTask?.cancel()
            widgetTokenRetryTask = nil
        }
    }

    /// WidgetKit can report configured widgets before its shared push token has
    /// finished generating. Retry that short bootstrap window without polling
    /// card data or keeping the app alive indefinitely.
    private func reconcileWidgetPushToken(
        allowEmptyConfigurations: Bool = false
    ) async -> Bool {
        guard apiClient() != nil else { return false }
        do {
            let configured = try await WidgetCenter.shared.currentConfigurations()
                .filter { ZeroZeroWidgetConstants.WidgetKinds.all.contains($0.kind) }
            if configured.isEmpty {
                let existing = WidgetPushTokenStore.load()
                let hasConfirmedEmptySnapshot = existing?.pushToken == nil
                    && existing?.subscriptions.isEmpty == true
                if !allowEmptyConfigurations && !hasConfirmedEmptySnapshot {
                    Self.widgetPushLog.info(
                        "widget configurations are not available yet; waiting before clearing registration"
                    )
                    return true
                }
                WidgetPushTokenStore.replace(pushToken: nil, subscriptions: [])
                _ = try await WidgetPushTokenRegistrar.registerCurrent()
                return false
            }

            guard let pushInfo = await WidgetCenter.shared.currentPushInfo else {
                // A saved token can still repair a changed device id while
                // WidgetKit finishes generating or rotating currentPushInfo.
                _ = try await WidgetPushTokenRegistrar.registerCurrent()
                Self.widgetPushLog.info(
                    "widget push token is still generating for \(configured.count, privacy: .public) configured widgets"
                )
                return true
            }

            let token = pushInfo.token.map { String(format: "%02x", $0) }.joined()
            let configuredKinds = Set(configured.map(\.kind))
            let existing = WidgetPushTokenStore.load()
            let existingKinds = Set(existing?.subscriptions.map(\.widgetKind) ?? [])
            let subscriptions: [WidgetPushSubscription]
            if existing?.pushToken == token, configuredKinds == existingKinds {
                subscriptions = existing?.subscriptions ?? []
            } else {
                // The handler normally provides card-level subscriptions. If
                // startup wins the race, use a conservative kind-level snapshot
                // until the callback supplies the exact selected card ids.
                subscriptions = configuredKinds.map {
                    WidgetPushSubscription(widgetKind: $0, allCards: true)
                }
            }
            WidgetPushTokenStore.replace(
                pushToken: token,
                subscriptions: subscriptions
            )
            _ = try await WidgetPushTokenRegistrar.registerCurrent()
            Self.widgetPushLog.info(
                "widget push token reconciled for \(configured.count, privacy: .public) configured widgets"
            )
            return false
        } catch {
            lastSyncError = "widget token register: \(error.localizedDescription)"
            Self.widgetPushLog.error(
                "widget token reconciliation failed: \(error.localizedDescription, privacy: .public)"
            )
            return true
        }
    }

    private func scheduleWidgetTokenRetries() {
        guard widgetTokenRetryTask == nil else { return }
        widgetTokenRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.widgetTokenRetryTask = nil }
            for delay in Self.widgetTokenRetryDelaysNanoseconds {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if !(await self.reconcileWidgetPushToken()) {
                    return
                }
            }
            if await self.reconcileWidgetPushToken(allowEmptyConfigurations: true) {
                Self.widgetPushLog.error(
                    "widget push token remained unavailable after bounded retries"
                )
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
