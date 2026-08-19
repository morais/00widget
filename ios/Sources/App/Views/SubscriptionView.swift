#if ZW_SUBSCRIPTIONS_ENABLED
import StoreKit
import SwiftUI

/// The paywall and subscription management screen.
///
/// App Review requires several things to be present and reachable here, none of
/// them optional: a Restore Purchases control, the price and billing period of
/// each option in plain text, the length of any free trial being advertised,
/// and links to the Terms of Use and Privacy Policy. Removing any of them is a
/// rejection, so they are not conveniences that can be tidied away.
struct SubscriptionView: View {
    @EnvironmentObject var subscriptions: SubscriptionController
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            statusSection

            if !subscriptions.state.active {
                offersSection
            }

            Section {
                Button("Restore purchases") {
                    Task { await subscriptions.restore() }
                }
                .disabled(subscriptions.isLoading)

                if subscriptions.state.active {
                    // Cancelling and switching plans both live in the App
                    // Store's own sheet. Reimplementing either is not possible.
                    Button("Manage subscription") {
                        openURL(Self.manageSubscriptionsURL)
                    }
                }
            } footer: {
                Text(Self.legalFooter)
            }

            Section {
                Link("Terms of Use", destination: Self.termsURL)
                Link("Privacy Policy", destination: Self.privacyURL)
            }

            if let error = subscriptions.lastError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Subscription")
        .task { await subscriptions.refresh() }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            KeyValue(key: "Status", value: statusLabel)
            if let expiresAt = subscriptions.state.expiresAt {
                KeyValue(key: renewalLabel, value: expiresAt.formatted(date: .abbreviated, time: .shortened))
            }
        } footer: {
            if subscriptions.state.needsAttention {
                Text(attentionMessage)
            } else if !subscriptions.isRequired && !subscriptions.state.active {
                // Being told to subscribe by a server that does not require one
                // reads as a bug. Say what is actually true.
                Text("This server doesn't require a subscription. Subscribing supports development.")
            }
        }
    }

    private var offersSection: some View {
        Section("Plans") {
            if subscriptions.products.isEmpty {
                // Distinguishable from "no plans exist": products fail to load
                // when the device is offline or the products are not yet
                // approved, and both look identical to an empty list.
                Text(subscriptions.isLoading ? "Loading plans…" : "Plans are unavailable right now.")
                    .foregroundStyle(.secondary)
            }
            ForEach(subscriptions.products, id: \.id) { product in
                Button {
                    Task { await subscriptions.purchase(product) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.displayName)
                            if let offer = introOfferLabel(for: product) {
                                Text(offer)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(priceLabel(for: product))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(subscriptions.purchaseInProgress)
            }
        }
    }

    private var statusLabel: String {
        switch subscriptions.state.status {
        case .none: return "Not subscribed"
        case .active: return "Active"
        case .trial: return "Free trial"
        case .grace: return "Payment issue"
        case .expired: return "Expired"
        case .revoked: return "Refunded"
        }
    }

    private var renewalLabel: String {
        subscriptions.state.autoRenew == false ? "Ends" : "Renews"
    }

    private var attentionMessage: String {
        switch subscriptions.state.status {
        case .grace:
            return "We couldn't take payment. Your widgets keep working for a few days while the App Store retries."
        case .expired, .revoked:
            return subscriptions.isRequired
                ? "Your agents can't publish new state until this is renewed. Existing widgets keep showing what they last received."
                : "Your subscription has ended."
        case .none, .active, .trial:
            return ""
        }
    }

    /// The trial length as Apple states it, and only when this Apple Account is
    /// actually eligible. Advertising a trial to someone who has already used
    /// one is a complaint waiting to happen.
    private func introOfferLabel(for product: Product) -> String? {
        guard
            subscriptions.isEligibleForIntroOffer,
            let offer = product.subscription?.introductoryOffer,
            offer.paymentMode == .freeTrial
        else { return nil }
        return "\(offer.period.formatted(product.subscriptionPeriodFormatStyle)) free, then"
    }

    private func priceLabel(for product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else {
            return product.displayPrice
        }
        return "\(product.displayPrice) / \(period.formatted(product.subscriptionPeriodFormatStyle))"
    }

    // App Store terms must be stated wherever a subscription is sold.
    private static let legalFooter = """
        Payment is charged to your Apple Account at confirmation of purchase. \
        Subscriptions renew automatically unless cancelled at least 24 hours \
        before the end of the current period. Manage or cancel in Settings › \
        Apple Account › Subscriptions.
        """

    private static let manageSubscriptionsURL =
        URL(string: "https://apps.apple.com/account/subscriptions")!
    private static let termsURL =
        URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let privacyURL =
        URL(string: "https://00widget.com/privacy")!
}

/// The banner the rest of the app shows when publishing is blocked.
///
/// Deliberately not a modal: the dashboard still has real content on it — the
/// last state every widget received — and covering that up would hide the thing
/// the person is most likely trying to check.
struct SubscriptionNotice: View {
    @EnvironmentObject var subscriptions: SubscriptionController

    var body: some View {
        if subscriptions.isRequired && !subscriptions.state.active {
            NavigationLink {
                SubscriptionView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Publishing is paused")
                            .font(.subheadline.weight(.medium))
                        Text("Your agents can't send new state until your subscription is active.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
#endif
