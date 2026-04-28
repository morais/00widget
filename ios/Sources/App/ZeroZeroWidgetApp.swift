import SwiftUI
import UIKit

@main
struct ZeroZeroWidgetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .onAppear {
                    delegate.env = env
                    Task { await env.registerPendingWidgetTokens() }
                }
                .onOpenURL { url in
                    openExternalDeepLink(url)
                }
        }
    }

    private func openExternalDeepLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        UIApplication.shared.open(url)
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

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }

            LiveActivitiesView()
                .tabItem { Label("Activities", systemImage: "waveform") }

            OnboardingView()
                .tabItem { Label("Settings", systemImage: "gearshape") }

            DeveloperView()
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
    }
}
