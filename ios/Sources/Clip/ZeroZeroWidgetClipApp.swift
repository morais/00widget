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
        ScrollView {
            VStack(spacing: 20) {
                content
            }
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        // A scroll view, because the thing being shown is a real card now: a
        // briefing with three sections is taller than a phone in a way a title
        // and a number never were.
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { footer }
    }

    @ViewBuilder
    private var content: some View {
        switch launcher.state {
        case .idle, .loading:
            ProgressView("Opening…")
                .padding(.top, 80)

        case .running(let session):
            GuestActivityPreview(session: session)
            confirmation(
                "Following on your Lock Screen.",
                symbol: "lock.iphone"
            )
            trustNote

        case .card(let card):
            // The production renderer, not a paraphrase of it. Every template,
            // chart, breakdown and briefing the sender could have shared
            // arrives looking the way it does in the app — which is the whole
            // demonstration a shared link gets to make.
            CardView(card: card, context: .app)
                .padding(18)
                .background(
                    .background.secondary,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            trustNote

        case .failed(let message):
            VStack(spacing: 16) {
                symbol("exclamationmark.triangle.fill")
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 60)
        }
    }

    private func confirmation(_ text: String, symbol name: String) -> some View {
        Label(text, systemImage: name)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// Beside the content rather than under a button. What someone needs to
    /// know about a link they were sent is what it can and cannot do, and as
    /// footer boilerplate under a call to action it read as fine print about
    /// the app instead.
    private var trustNote: some View {
        Text("Read-only · The owner can revoke this link")
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }

    private var footer: some View {
        Button(callToAction) { showAppStoreOverlay = true }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
            .appStoreOverlay(isPresented: $showAppStoreOverlay) {
                SKOverlay.AppClipConfiguration(position: .bottom)
            }
    }

    /// What the app would do *next* for this person, rather than its name. The
    /// two successful states want different sentences: one has something to
    /// keep watching, the other something to keep.
    private var callToAction: String {
        switch launcher.state {
        case .running: return "Keep following in 00Widget"
        case .card: return "Keep this card in 00Widget"
        case .idle, .loading, .failed: return "Get 00Widget"
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.largeTitle)
            .foregroundStyle(.tint)
    }
}
