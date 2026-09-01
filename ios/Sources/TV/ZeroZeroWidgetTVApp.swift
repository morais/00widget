import SwiftUI

@main
struct ZeroZeroWidgetTVApp: App {
    @StateObject private var env = TVEnvironment()

    var body: some Scene {
        WindowGroup {
            root
        }
    }

    @ViewBuilder
    private var root: some View {
        #if ZW_SCREENSHOTS
        if ProcessInfo.processInfo.arguments.contains("--large-text-preview") {
            TVRootView()
                // Xcode 26 cannot drive a tvOS system text-size setting. This
                // private screenshot/test path exercises the same environment
                // value tvOS 27 will provide, without shipping an app setting.
                .environment(\.dynamicTypeSize, .accessibility3)
                .environmentObject(env)
                .task { await env.startupSync() }
        } else {
            standardRoot
        }
        #else
        standardRoot
        #endif
    }

    private var standardRoot: some View {
        TVRootView()
            .environmentObject(env)
            .task { await env.startupSync() }
    }
}
