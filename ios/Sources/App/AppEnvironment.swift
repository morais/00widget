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
    /// Links other people shared with this device. Independent of `apiKey`:
    /// somebody who has never signed in can hold several, which is the whole
    /// point of a guest link.
    @Published public private(set) var guestLinks: [GuestLink] = []
    @Published public private(set) var guestCards: [DashboardCard] = []
    @Published public private(set) var guestActivities: [LiveActivitySession] = []
    @Published public private(set) var guestRefreshError: String?
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
        self.guestLinks = GuestLinkStore.load()
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
        // Deliberately leaves guestLinks alone. Those are other people's
        // resources shared *with* this device; signing out of this account has
        // nothing to do with them. Links this account *minted* are revoked
        // server-side by the same sign-out call.
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

    // MARK: - Guest links

    /// True when this device can show something: an account of its own, or at
    /// least one link somebody shared with it. The app opens on Settings only
    /// when neither is true.
    public var hasAnyAccess: Bool {
        !apiKey.isEmpty || !guestLinks.isEmpty
    }

    public enum GuestLinkResult: Equatable {
        case added(title: String)
        case alreadyHeld(title: String)
        case invalid
        case expired
        case failed(String)
    }

    /// Accepts a token from a scanned QR code or an opened link, verifies it
    /// against the server, and keeps it only if it actually unlocks something.
    /// Storing an unverified token would leave a row that can never render.
    @discardableResult
    public func addGuestLink(token rawToken: String) async -> GuestLinkResult {
        guard GuestToken.looksValid(rawToken) else { return .invalid }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = APIClientConfig.validatedBaseURL(from: serverBaseURL) else {
            return .failed("Server URL must use HTTPS")
        }
        let alreadyHeld = guestLinks.contains { $0.token == token }
        do {
            let resource = try await APIClient.guest(baseURL: url, token: token).fetchGuestResource()
            let link = GuestLink(
                token: token,
                resourceKind: resource.resourceKind,
                resourceId: resource.card?.id ?? resource.activity?.id,
                title: resource.card?.title ?? resource.activity?.title,
                expiresAt: resource.expiresAt,
                addedAt: guestLinks.first { $0.token == token }?.addedAt ?? Date()
            )
            guestLinks = GuestLinkStore.add(link)
            applyGuestResource(resource, for: token)
            guestRefreshError = nil
            persistGuestCardsForWidgets()
            await syncGuestActivities()
            let title = link.title ?? "Shared item"
            return alreadyHeld ? .alreadyHeld(title: title) : .added(title: title)
        } catch let error as APIClientError where error.status == 401 {
            // Revoked, expired, or simply never valid — the server does not
            // distinguish, and neither should the message.
            return .expired
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Surfaced by the dashboard so an opened link reports its outcome the way
    /// the scanner does, rather than appearing to do nothing.
    @Published public var guestLinkBanner: String?

    /// Tab requested by an incoming app or guest link. Keeping the destination
    /// in the environment lets a cold launch deliver its URL before RootView
    /// has finished constructing the tab bar.
    @Published public var requestedLandingTab: String?

    public func reportGuestLinkProblem(_ message: String) {
        guestLinkBanner = message
    }

    /// Takes a link and reports the outcome. One path for the scanner and for
    /// an opened universal link, so the two cannot drift apart in what they
    /// accept, how they fail, or where they leave the person afterwards.
    @discardableResult
    public func acceptGuestLink(token: String) async -> GuestLinkResult {
        let result = await addGuestLink(token: token)
        switch result {
        case .added(let title):
            guestLinkBanner = "Added \u{201C}\(title)\u{201D}."
            requestedLandingTab = landingTab(forTokenNamed: token)
        case .alreadyHeld(let title):
            guestLinkBanner = "You already have \u{201C}\(title)\u{201D}."
            requestedLandingTab = landingTab(forTokenNamed: token)
        case .invalid:
            guestLinkBanner = "That is not a 00Widget link."
        case .expired:
            guestLinkBanner = "That link has expired or been revoked."
        case .failed(let message):
            guestLinkBanner = message
        }
        return result
    }

    /// A Live Activity lives on the Activities tab and a card on the dashboard,
    /// so "where did it go" has two answers.
    private func landingTab(forTokenNamed token: String) -> String {
        let kind = guestLinks.first { $0.token == token }?.resourceKind
        return kind == "activity" ? "activities" : "widgets"
    }

    /// Mints a read-only link for one card or activity.
    ///
    /// Runs on the app credential, not `apiClient()`. Minting needs
    /// `shares:manage`, which lives on the app credential exactly like every
    /// other sharing call — the primary token carries the device preset and
    /// would 403.
    public func createGuestLink(
        resourceKind: String,
        resourceId: String
    ) async throws -> APIClient.GuestLinkResponse {
        guard let client = confirmedActionClient() else {
            throw APIClientError(status: 0, message: Self.reauthorizationMessage)
        }
        return try await client.createGuestLink(resourceKind: resourceKind, resourceId: resourceId)
    }

    /// Links this account has handed out. Runs on the app credential, like
    /// every other shares:manage call.
    public func fetchSharedGuestLinks() async throws -> [APIClient.GuestLinkSummary] {
        guard let client = confirmedActionClient() else {
            throw APIClientError(status: 0, message: Self.reauthorizationMessage)
        }
        return try await client.listGuestLinks()
    }

    public func revokeSharedGuestLink(id: String) async throws {
        guard let client = confirmedActionClient() else {
            throw APIClientError(status: 0, message: Self.reauthorizationMessage)
        }
        try await client.revokeGuestLink(id: id)
    }

    public func removeGuestLink(token: String) {
        let removed = guestLinks.first { $0.token == token }
        guestLinks = GuestLinkStore.remove(token: token)
        rebuildGuestResources()
        persistGuestCardsForWidgets()
        Task {
            if removed?.resourceKind == "activity", let id = removed?.resourceId {
                await liveActivityController.endGuestActivity(instanceId: id)
            }
            await syncGuestActivities()
        }
    }

    /// Re-reads every held link. Expired ones are dropped rather than left to
    /// fail silently on every refresh.
    public func refreshGuestLinks() async {
        guard !guestLinks.isEmpty else {
            guestCards = []
            guestActivities = []
            return
        }
        guard let url = APIClientConfig.validatedBaseURL(from: serverBaseURL) else { return }

        var cards: [DashboardCard] = []
        var activities: [LiveActivitySession] = []
        var surviving: [GuestLink] = []
        var lastError: String?
        var droppedInstanceIds: Set<String> = []

        for link in guestLinks {
            do {
                let resource = try await APIClient.guest(baseURL: url, token: link.token)
                    .fetchGuestResource()
                var updated = link
                updated.resourceKind = resource.resourceKind
                updated.title = resource.card?.title ?? resource.activity?.title
                updated.expiresAt = resource.expiresAt
                updated.resourceId = resource.card?.id ?? resource.activity?.id
                surviving.append(updated)
                if let card = resource.card { cards.append(card) }
                if let activity = resource.activity { activities.append(activity) }
            } catch let error as APIClientError where error.status == 401 {
                // Gone for good: guest tokens never renew, so a 401 is final.
                if link.resourceKind == "activity", let id = link.resourceId {
                    droppedInstanceIds.insert(id)
                }
                continue
            } catch {
                // A transient failure must not discard a link that may still be
                // perfectly valid, so keep it and surface the problem instead.
                surviving.append(link)
                lastError = error.localizedDescription
            }
        }

        guestLinks = surviving
        GuestLinkStore.save(surviving)
        guestCards = cards
        guestActivities = activities
        guestRefreshError = lastError
        persistGuestCardsForWidgets()
        await syncGuestActivities(dropped: droppedInstanceIds)
    }

    /// Hands the controller the tokens for followed activities and starts a
    /// Live Activity for each one, so the owner's updates land on this device's
    /// Lock Screen. Ends the ones whose links have gone.
    private func syncGuestActivities(dropped: Set<String> = []) async {
        var tokens: [String: String] = [:]
        for link in guestLinks where link.resourceKind == "activity" && !link.hasExpired {
            if let id = link.resourceId { tokens[id] = link.token }
        }
        liveActivityController.setGuestActivityTokens(tokens)

        for instanceId in dropped {
            await liveActivityController.endGuestActivity(instanceId: instanceId)
        }
        for activity in guestActivities {
            do {
                try await liveActivityController.startGuestActivity(activity)
            } catch {
                guestRefreshError = error.localizedDescription
            }
        }
    }

    private func applyGuestResource(_ resource: GuestResourceResponse, for token: String) {
        if let card = resource.card {
            guestCards.removeAll { $0.id == card.id }
            guestCards.append(card)
        }
        if let activity = resource.activity {
            guestActivities.removeAll { $0.id == activity.id }
            guestActivities.append(activity)
        }
    }

    /// Guest cards live in their own App Group file, so a widget refresh that
    /// overwrites the tenant's cache cannot take them with it.
    private func persistGuestCardsForWidgets() {
        // Pair each card with its link's deadline. The extension cannot ask the
        // server whether a link is still good, so the expiry has to travel with
        // the data or an expired card lingers on the Home Screen until somebody
        // happens to open the app.
        let entries = guestCards.map { card in
            GuestCachedCard(
                card: card,
                expiresAt: guestLinks.first { $0.resourceId == card.id }?.expiresAt
            )
        }
        try? GuestCardCache.save(entries)
        WidgetCenter.shared.reloadTimelines(ofKind: ZeroZeroWidgetConstants.WidgetKinds.card)
        WidgetCenter.shared.reloadTimelines(ofKind: ZeroZeroWidgetConstants.WidgetKinds.cardGrid)
    }

    private func rebuildGuestResources() {
        let heldIds = Set(guestLinks.compactMap { $0.resourceId })
        guestCards = guestCards.filter { heldIds.contains($0.id) }
        guestActivities = guestActivities.filter { heldIds.contains($0.id) }
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

    /// A client on the publisher credential.
    ///
    /// Deleting a card is a `publish`-scoped write, and the device credential
    /// this app authenticates most calls with carries `read`,
    /// `device:register`, and `actions:run` — not `publish`. The publisher
    /// token is the one that can, and is the same token Settings hands to an
    /// agent, so a manually pasted producer key works here too.
    public func publisherClient() -> APIClient? {
        guard
            let url = APIClientConfig.validatedBaseURL(from: serverBaseURL),
            !agentApiKey.isEmpty
        else { return nil }
        return APIClient(config: APIClientConfig(baseURL: url, apiKey: agentApiKey))
    }

    /// Removes a card from the account, not just from this device.
    ///
    /// Samples never reached the server — they are generated on-device
    /// straight into the App Group — so deleting one is a local edit and
    /// needs no credential, which also keeps the samples removable for a user
    /// who has never signed in.
    ///
    /// Everything else goes to the server first. Dropping the card locally on
    /// a failed request would let the next fetch bring it straight back, with
    /// nothing said about why.
    public func deleteCard(_ card: DashboardCard) async throws {
        if !card.isSample {
            guard let client = publisherClient() else {
                throw APIClientError(
                    status: 0,
                    message: "Server URL or API key not configured."
                )
            }
            try await client.deleteCard(id: card.id)
        }
        removeCardLocally(id: card.id)
    }

    private func removeCardLocally(id: String) {
        var cached = CardCache.load().cards
        cached.removeAll { $0.id == id }
        try? CardCache.save(cached)
        cards.removeAll { $0.id == id }
        reloadWidgetTimelines()
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
        await refreshGuestLinks()
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
        await refreshGuestLinks()
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
