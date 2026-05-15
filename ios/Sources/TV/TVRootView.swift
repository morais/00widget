import SwiftUI

struct TVRootView: View {
    @EnvironmentObject var env: TVEnvironment

    var body: some View {
        Group {
            if env.isSignedIn {
                TVDashboardView()
            } else {
                TVSignInView()
            }
        }
    }
}
