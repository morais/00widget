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
    /// Distinguishes a genuinely empty account from the brief interval before
    /// the first network response. Cached content may still render immediately.
    @Published private(set) var hasCompletedInitialSync = false

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
        } else if screenshotSection == "typography" {
            // A regression fixture for the tightest hierarchy on a dashboard
            // card: a short range value followed by a long contextual line.
            // Semantic tvOS styles made the latter appear larger even when its
            // nominal point size was slightly smaller.
            self.cards = [
                DashboardCard(
                    id: SampleDataFactory.sampleId("tv-typography"),
                    template: .chart,
                    title: "Basement Humidity",
                    subtitle: "Min–max RH · Jul 29–Aug 29 · target 40–60%",
                    value: "57–73",
                    unit: "%",
                    status: .warning,
                    icon: "humidity",
                    updatedAt: Date(),
                    chart: DashboardChart(
                        points: [68, 66, 64, 65, 61, 59, 62, 58, 57, 60, 63, 67, 71, 73],
                        min: 40,
                        max: 80,
                        semantic: MetricSemantic(role: .actual, signal: .caution),
                        style: .line
                    )
                )
            ]
        } else if screenshotSection == "detail-budget" {
            // A regression fixture for the detail panel's row budget, not a
            // marketing shot. It is the compound worst case: a list at its row
            // cap, a subtitle at the API's 240-character limit, a deadline,
            // and actions in the footer. The budget counted only the first of
            // those, so this card drew six rows into the room for four — and a
            // panel that overruns is centred rather than clipped, so it lost
            // its header off the top and its buttons off the bottom, on a
            // column nothing can scroll to.
            self.cards = [
                DashboardCard(
                    id: SampleDataFactory.sampleId("tv-detail-budget"),
                    template: .list,
                    title: "Fleet checks",
                    subtitle: "Last 30 days of household consumption including the heat pump, the car charger and the workshop sub-meter, compared against the same window last year and the tariff cap agreed in March for the winter",
                    value: "8",
                    unit: "checks",
                    status: .warning,
                    icon: "server.rack",
                    updatedAt: Date(),
                    deadline: Date().addingTimeInterval(7200),
                    items: (0..<8).map { index in
                        DashboardItem(
                            id: "row\(index)",
                            title: ["Edge cache", "Origin", "Database", "Queue", "Webhooks", "Search", "Billing", "Auth"][index],
                            value: "\(120 + index * 17)",
                            unit: "ms",
                            status: index == 3 ? .critical : .good,
                            amount: Double(120 + index * 17)
                        )
                    },
                    actions: [
                        ActionDefinition(id: "recheck", label: "Recheck all"),
                        ActionDefinition(id: "drain", label: "Drain queue")
                    ]
                )
            ]
        } else if screenshotSection == "insights" {
            let insightIds = ["trials", "support", "agent-runs"].map(SampleDataFactory.sampleId)
            self.cards = insightIds.compactMap { id in samples.first { $0.id == id } }
        } else if screenshotSection == "widgets" {
            // Two full rows, which is what the screen holds. A third row is
            // reachable by scrolling and is the right behaviour on a device,
            // but a marketing capture that slices one through the middle of a
            // number reads as a bug rather than as an affordance. Keep the
            // publication-order prefix here; the dedicated insights capture
            // separately selects Trials, Support, and Agent runs.
            self.cards = Array(samples.dropLast(2))
        } else {
            self.cards = samples
        }
        self.liveActivities = screenshotSection == "widgets" || screenshotSection == "typography"
            ? []
            : [TVEnvironment.screenshotLiveActivity(section: screenshotSection)]
        self.hasCompletedInitialSync = true
        SharedSettings.setHideSampleIndicators(true)
        #else
        let defaults = UserDefaults.standard
        self.serverBaseURL = ZeroZeroWidgetConstants.defaultServerBaseURL
        self.apiKey = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? ""
        self.appleLoginEmail = defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appleLoginEmail)
        self.cards = CardCache.load().cards
        #endif
    }

    #if ZW_SCREENSHOTS
    /// The `focus` section is not a marketing shot. It is the one geometry in
    /// which the Widgets section sits entirely below the fold — a composite
    /// activity draws a row per item, and a card tall enough to push the
    /// widgets off screen is what made them unreachable when the grid building
    /// them was lazy. `TVFocusNavigationTests` needs that state to exist to
    /// press down against it.
    private static func screenshotLiveActivity(section: String?) -> LiveActivitySession {
        var session = SampleDataFactory.makeLiveActivitySession()
        guard section == "focus" else { return session }
        session.items = [
            LiveActivityItem(id: "1", title: "Master Bedroom", subtitle: "Cooling to 20°C", icon: "snowflake", value: "23.2", unit: "°C", status: .running),
            LiveActivityItem(id: "2", title: "Office", subtitle: "Cooling to 20°C", icon: "snowflake", value: "23.6", unit: "°C", status: .running),
            LiveActivityItem(id: "3", title: "Kitchen", subtitle: "Cooling to 20°C", icon: "snowflake", value: "22.6", unit: "°C", status: .running),
            LiveActivityItem(id: "4", title: "Living Room", subtitle: "Cooling to 20°C", icon: "snowflake", value: "23.3", unit: "°C", status: .running),
        ]
        return session
    }
    #endif

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
        hasCompletedInitialSync = false
        await refreshAccount()
        if isSignedIn { await fetchCards() }
        hasCompletedInitialSync = true
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
                deviceId: SharedSettings.deviceId(),
                // Apple TV has no Agent-config surface. Minting a publisher
                // token here would create a secret the television never shows
                // or stores.
                issuePublisherCredential: false
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
            hasCompletedInitialSync = false
            await fetchCards()
            hasCompletedInitialSync = true
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
        let response: AccountResponse
        do {
            response = try await client.fetchAccount()
        } catch let error as APIClientError where error.status == 401 {
            clearLocalCredentials()
            return
        } catch {
            return
        }
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
        let appClient = confirmedActionClient()
        var shouldTryDeviceCredential = appClient == nil
        if let client = appClient {
            do {
                try await client.revokeCurrentCredential()
            } catch let error as APIClientError where error.status == 401 {
                shouldTryDeviceCredential = true
            } catch {
                // Local sign-out must complete even when server cleanup cannot.
            }
        }
        if shouldTryDeviceCredential, let client = apiClient() {
            try? await client.revokeCurrentCredential()
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
        hasCompletedInitialSync = false
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
            if let error = error as? APIClientError, error.status == 401 {
                clearLocalCredentials()
                return
            }
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
