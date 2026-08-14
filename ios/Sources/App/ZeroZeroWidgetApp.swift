import SwiftUI
import UIKit

@main
struct ZeroZeroWidgetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .onAppear {
                    delegate.env = env
                    Task { await env.startupSync() }
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await env.syncAfterForeground() }
                }
        }
    }

    /// `onOpenURL` sees two unrelated kinds of URL: card and Live Activity deep
    /// links, which belong to whoever published them and open in the browser,
    /// and — since the app claims `applinks:` — universal links for our own
    /// host, which must not be forwarded. Handing one of those to
    /// `UIApplication.open` gives it straight back to iOS, which routes it to
    /// this app again.
    private func handleIncomingURL(_ url: URL) {
        if let route = ZeroZeroWidgetUniversalLink.route(for: url, serverBaseURL: env.serverBaseURL) {
            handleUniversalLink(route: route, url: url)
            return
        }
        openExternalDeepLink(url)
    }

    /// Guest links are the only route so far. The token is in the fragment, so
    /// it arrives here having never been sent to the server — the reason the
    /// URL is shaped that way in the first place.
    private func handleUniversalLink(route: String, url: URL) {
        guard route == "g" || route.hasPrefix("g/") else { return }
        guard let token = GuestToken.fromURL(url) else {
            // A /app/g link with no usable token in the fragment. Opening the
            // browser fallback would only show the same "missing its code"
            // message, so say it here instead of bouncing the person out.
            env.reportGuestLinkProblem("That link is missing its code. Ask for it again.")
            return
        }
        Task { await env.acceptGuestLinkFromURL(token: token) }
    }

    private func openExternalDeepLink(_ url: URL) {
        guard let safeURL = ZeroZeroWidgetDeepLinkPolicy.sanitize(url) else { return }
        UIApplication.shared.open(safeURL)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var env: AppEnvironment?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Touch the singleton early so its push-to-start observer is established
        // in didFinishLaunchingWithOptions — Apple's docs say tokens only fire
        // when observation is set up this early in the launch lifecycle.
        Task { @MainActor in _ = LiveActivityController.shared }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            env?.setAPNsDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("Failed to register for remote notifications: \(error)")
    }
}

struct RootView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var selectedTab: String

    init() {
        // Holding a link somebody shared is as good a reason to open on the
        // dashboard as having an account: a guest may never sign in at all.
        let hasKey = !(KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? "").isEmpty
        let hasGuestLinks = !GuestLinkStore.load().isEmpty
        _selectedTab = State(initialValue: hasKey || hasGuestLinks ? "widgets" : "settings")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
                .tag("widgets")

            if env.showActivitiesTab {
                LiveActivitiesView()
                    .tabItem { Label("Activities", systemImage: "waveform") }
                    .tag("activities")
            }

            // Debug tools live under Settings → Developer, not as a tab. The
            // tab bar is in every screenshot and on every screen, so it stays
            // the same three entries whether or not debug builds are enabled.
            OnboardingView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        // An opened link lands on the dashboard, where the new card is, rather
        // than leaving the outcome on whichever tab happened to be showing.
        .onChange(of: env.guestLinkBanner) { _, banner in
            if banner != nil { selectedTab = "widgets" }
        }
    }
}
