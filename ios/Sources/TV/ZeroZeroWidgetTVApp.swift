import SwiftUI

@main
struct ZeroZeroWidgetTVApp: App {
    @StateObject private var env = TVEnvironment()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(env)
                .task { await env.startupSync() }
        }
    }
}
