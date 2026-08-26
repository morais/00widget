import SwiftUI

struct TVSettingsView: View {
    @EnvironmentObject var env: TVEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    #if ZW_SUBSCRIPTIONS_ENABLED
    @State private var subscription: SubscriptionState?
    #endif

    var body: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()

            VStack(spacing: 32) {
                Text("Settings")
                    .font(.system(size: 56, weight: .bold))

                // A Grid rather than a stack of fixed-width labels: the first
                // column takes the width of the widest key, so a long one like
                // "Subscription" is never hyphenated across two lines and a
                // short one wastes no space.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 28, verticalSpacing: 18) {
                    row("Signed in as", value: env.appleLoginEmail ?? "—")
                    row("Server", value: env.serverBaseURL)
                    row("Version", value: appVersionString)
                    if let last = env.lastSyncAt {
                        row("Last sync", value: last.formatted(.relative(presentation: .named)))
                    }
                    if let error = env.lastSyncError {
                        row("Last error", value: error, valueColor: .red)
                    }
                    // Where a failed deletion or sign-out reports itself: this
                    // screen has no other place to put an account error.
                    if let error = env.appleLoginError {
                        row("Account", value: error, valueColor: .red)
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
                    Button {
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

                    // Apple requires deletion to be offered wherever an account
                    // can be created, and this app signs in with Apple too.
                    // No destructive role, for the reason above; the danger is
                    // carried by the red label and by the confirmation, which
                    // does use the role — a dialog draws it as emphasis rather
                    // than as a fill.
                    Button {
                        confirmingDelete = true
                    } label: {
                        Label(
                            env.accountDeletionInProgress ? "Deleting…" : "Delete account",
                            systemImage: "trash"
                        )
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                    }
                    .disabled(env.accountDeletionInProgress)
                    // On the button rather than on the screen: a confirmation
                    // presented from a container anchors to the container.
                    .confirmationDialog(
                        "Delete your account?",
                        isPresented: $confirmingDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Delete account", role: .destructive) {
                            Task {
                                if await env.deleteAccount() { dismiss() }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This permanently deletes your account and everything in it: every card, every Live Activity, every agent token, and the widgets on your other devices. It cannot be undone, and signing in again starts an empty account.")
                    }

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

    private func row(_ key: String, value: String, valueColor: Color = .primary) -> some View {
        GridRow {
            Text(key)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.title3)
                .foregroundStyle(valueColor)
                .lineLimit(2)
                .truncationMode(.middle)
                .gridColumnAlignment(.leading)
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }
}
