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
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var env: AppEnvironment?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
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
