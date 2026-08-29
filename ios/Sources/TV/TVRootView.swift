import SwiftUI

struct TVRootView: View {
    @EnvironmentObject var env: TVEnvironment
    @State private var showingSettings = false

    var body: some View {
        Group {
            if env.isSignedIn {
                TVDashboardView(showingSettings: $showingSettings)
            } else {
                TVSignInView()
            }
        }
        // The cover does not make its presenter inert: with Settings up, the
        // dashboard behind it — its own Settings button, every card, and every
        // card action — was still enumerable by assistive technology, so
        // VoiceOver could wander into a screen the viewer cannot see or reach.
        .accessibilityHidden(showingSettings)
        // Settings is presented from the root rather than from the dashboard,
        // because signing out and deleting the account both replace the
        // dashboard with the sign-in view from inside the presented screen. A
        // cover whose presenter is torn down mid-presentation is left on
        // screen with a `dismiss()` that no longer reaches it — which is how a
        // deleted account went on showing Settings over a stale dashboard, and
        // invited a second Delete that could only answer "not authorized".
        .fullScreenCover(isPresented: $showingSettings) {
            TVSettingsView()
                .environmentObject(env)
        }
        // The account state decides, not the screen that changed it: whatever
        // signs this device out closes Settings, including a sign-out the
        // Settings screen did not initiate.
        .onChange(of: env.isSignedIn) { _, signedIn in
            if !signedIn { showingSettings = false }
        }
    }
}
