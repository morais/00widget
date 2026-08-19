import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject var env: TVEnvironment
    @Environment(\.dismiss) private var dismiss
    #if ZW_SUBSCRIPTIONS_ENABLED
    @State private var subscription: SubscriptionState?
    #endif

    var body: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()

            VStack(spacing: 32) {
                Text("Settings")
                    .font(.system(size: 56, weight: .bold))

                VStack(alignment: .leading, spacing: 18) {
                    row("Signed in as", value: env.appleLoginEmail ?? "—")
                    row("Server", value: env.serverBaseURL)
                    row("Version", value: appVersionString)
                    if let last = env.lastSyncAt {
                        row("Last sync", value: last.formatted(.relative(presentation: .named)))
                    }
                    if let error = env.lastSyncError {
                        row("Last error", value: error, valueColor: .red)
                    }
                    #if ZW_SUBSCRIPTIONS_ENABLED
                    if let subscription {
                        row("Subscription", value: subscriptionLabel(subscription))
                    }
                    #endif
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(36)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.08)))

                HStack(spacing: 24) {
                    Button(role: .destructive) {
                        Task {
                            if await env.signOut() {
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                    }
                    .disabled(env.signOutInProgress)

                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .padding(.horizontal, 48)
                            .padding(.vertical, 16)
                    }
                }
            }
            .padding(60)
        }
        #if ZW_SUBSCRIPTIONS_ENABLED
        .task { await loadSubscription() }
        #endif
    }

    #if ZW_SUBSCRIPTIONS_ENABLED
    /// Read-only on purpose. The tvOS app shares the iOS app's bundle
    /// identifier and App Store record, so a subscription bought on iPhone
    /// already entitles this device through the same Apple Account — and a
    /// purchase flow driven by a remote control is a worse way to sell one.
    private func loadSubscription() async {
        guard let config = APIClientConfig.fromSettings() else { return }
        subscription = try? await APIClient(config: config).subscriptionStatus().subscription
    }

    private func subscriptionLabel(_ state: SubscriptionState) -> String {
        switch state.status {
        case .active: return "Active"
        case .trial: return "Free trial"
        case .grace: return "Payment issue"
        case .expired: return "Expired — renew on your iPhone"
        case .revoked: return "Refunded"
        case .none: return "Not subscribed — subscribe on your iPhone"
        }
    }
    #endif

    @ViewBuilder
    private func row(_ key: String, value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 240, alignment: .leading)
            Text(value)
                .font(.title3)
                .foregroundStyle(valueColor)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }
}
