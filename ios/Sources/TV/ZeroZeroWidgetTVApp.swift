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
        if let previewSize = TVLargeTextPreview.requestedSize {
            TVRootView()
                // Xcode 26 cannot drive a tvOS system text-size setting. This
                // private screenshot/test path exercises the same environment
                // value tvOS 27 will provide, without shipping an app setting.
                .environment(\.dynamicTypeSize, previewSize)
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

#if ZW_SCREENSHOTS
/// `--large-text-preview [size]`, where `size` names a `DynamicTypeSize` case.
///
/// The size is an argument rather than a constant because the two halves of
/// the range are two different layouts — see `TVTextScale`. Exercising only the
/// accessibility half left the enlarged one, where the grid keeps its three
/// columns and a cell keeps a fixed height, covered by nothing at all. Omit it
/// and it stays `.accessibility3`, so existing capture and test runs are
/// unchanged.
enum TVLargeTextPreview {
    private static let sizes: [String: DynamicTypeSize] = [
        "xSmall": .xSmall,
        "small": .small,
        "medium": .medium,
        "large": .large,
        "xLarge": .xLarge,
        "xxLarge": .xxLarge,
        "xxxLarge": .xxxLarge,
        "accessibility1": .accessibility1,
        "accessibility2": .accessibility2,
        "accessibility3": .accessibility3,
        "accessibility4": .accessibility4,
        "accessibility5": .accessibility5,
    ]

    static var requestedSize: DynamicTypeSize? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--large-text-preview") else { return nil }
        let next = arguments.index(after: flag)
        guard arguments.indices.contains(next), !arguments[next].hasPrefix("--") else {
            return .accessibility3
        }
        return sizes[arguments[next]] ?? .accessibility3
    }
}
#endif
