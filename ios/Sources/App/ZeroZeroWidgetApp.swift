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
                    openExternalDeepLink(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await env.syncAfterForeground() }
                }
        }
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
        let hasKey = !(KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey) ?? "").isEmpty
        _selectedTab = State(initialValue: hasKey ? "widgets" : "settings")
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
    }
}
