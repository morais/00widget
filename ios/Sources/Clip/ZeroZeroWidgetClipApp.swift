import SwiftUI
import StoreKit

@main
struct ZeroZeroWidgetClipApp: App {
    @StateObject private var launcher = GuestActivityLauncher()

    var body: some Scene {
        WindowGroup {
            ClipRootView()
                .environmentObject(launcher)
                // A clip is always launched *from* a URL, so this is the only
                // entry point it has — there is no state to restore and nothing
                // to show anyone who arrives without one.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard
                        let url = activity.webpageURL,
                        let token = GuestToken.fromURL(url)
                    else { return }
                    Task { await launcher.open(token: token) }
                }
        }
    }
}

struct ClipRootView: View {
    @EnvironmentObject var launcher: GuestActivityLauncher
    @State private var showAppStoreOverlay = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            content
            Spacer()
            footer
        }
        .padding(24)
        .multilineTextAlignment(.center)
        .task {
            // onContinueUserActivity arrives after the first render, so give it
            // a moment before concluding there is no link.
            try? await Task.sleep(for: .seconds(2))
            launcher.reportMissingInvocation()
        }
        .appStoreOverlay(isPresented: $showAppStoreOverlay) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch launcher.state {
        case .idle, .loading:
            ProgressView("Opening…")

        case .running(let title):
            symbol("bolt.badge.clock.fill")
            Text(title).font(.title2.weight(.semibold))
            Text("It's on your Lock Screen and will keep updating.")
                .foregroundStyle(.secondary)

        case .card(let title, let value):
            symbol("square.grid.2x2.fill")
            Text(title).font(.title2.weight(.semibold))
            if let value {
                Text(value)
                    .font(.largeTitle.weight(.semibold))
                    .fontDesign(.rounded)
            }
            Text("Get 00Widget to keep this on your Home Screen.")
                .foregroundStyle(.secondary)

        case .failed(let message):
            symbol("exclamationmark.triangle.fill")
            Text(message).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button("Get 00Widget") { showAppStoreOverlay = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("Read-only. Whoever shared this can stop it at any time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.largeTitle)
            .foregroundStyle(.tint)
    }
}
