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
                Button(subscriptions.isLoading ? "Restoring…" : "Restore purchases") {
                    Task {
                        let outcome = await subscriptions.restore()
                        AccessibilityAnnouncement.post(outcome)
                    }
                }
                .disabled(subscriptions.isLoading || subscriptions.purchaseInProgress)
                .accessibilityValue(subscriptions.isLoading ? "In progress" : "")

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
            KeyValue(key: "Status", value: subscriptions.state.displayLabel)
            if subscriptions.state.environment == "Sandbox" {
                KeyValue(key: "Environment", value: "Sandbox")
            }
            if let expiresAt = subscriptions.state.expiresAt {
                KeyValue(key: renewalLabel, value: expiresAt.formatted(date: .abbreviated, time: .shortened))
            }
        } footer: {
            if subscriptions.state.needsAttention {
                Text(attentionMessage)
            } else if !subscriptions.isRequired && !subscriptions.state.active {
                Text("Subscribing supports ongoing development and server costs.")
            }
        }
    }

    private var offersSection: some View {
        Section("Plans") {
            if subscriptions.products.isEmpty {
                #if ZW_SCREENSHOTS
                ForEach(subscriptions.screenshotPlans) { plan in
                    Button {} label: {
                        planLabel(
                            name: plan.displayName,
                            offer: plan.offerLabel,
                            price: plan.priceLabel
                        )
                    }
                }
                if subscriptions.screenshotPlans.isEmpty {
                    unavailablePlansLabel
                }
                #else
                unavailablePlansLabel
                #endif
            }
            ForEach(subscriptions.products, id: \.id) { product in
                Button {
                    Task {
                        let outcome = await subscriptions.purchase(product)
                        AccessibilityAnnouncement.post(outcome)
                    }
                } label: {
                    if subscriptions.purchaseInProgress {
                        Text("Purchasing…")
                    } else {
                        planLabel(
                            name: product.displayName,
                            offer: introOfferLabel(for: product),
                            price: priceLabel(for: product)
                        )
                    }
                }
                .disabled(subscriptions.purchaseInProgress || subscriptions.isLoading)
                .accessibilityValue(subscriptions.purchaseInProgress ? "In progress" : "")
            }
        }
    }

    private var unavailablePlansLabel: some View {
        // Distinguishable from "no plans exist": products fail to load when
        // the device is offline or the products are not yet approved, and both
        // look identical to an empty list.
        Text(subscriptions.isLoading ? "Loading plans…" : "Plans are unavailable right now.")
            .foregroundStyle(.secondary)
    }

    private func planLabel(name: String, offer: String?, price: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                if let offer {
                    Text(offer)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: Capsule()
                        )
                }
            }
            Spacer()
            Text(price)
                .foregroundStyle(.secondary)
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
        return "\(offer.period.formatted(product.subscriptionPeriodFormatStyle)) free"
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
    private static let termsURL = ZeroZeroWidgetConstants.Legal.terms
    private static let privacyURL = ZeroZeroWidgetConstants.Legal.privacy
}

/// The banner the rest of the app shows when publishing is blocked.
///
/// Deliberately not a modal: the dashboard still has real content on it — the
/// last state every widget received — and covering that up would hide the thing
/// the person is most likely trying to check.
struct SubscriptionNotice: View {
    @EnvironmentObject var subscriptions: SubscriptionController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if subscriptions.isRequired && !subscriptions.state.active {
            NavigationLink {
                SubscriptionView()
            } label: {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
                layout {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Publishing is paused")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Your agents can't send new state until your subscription is active.")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            // Named only so the accessibility audit can
                            // exclude it by identity rather than by its
                            // wording — see the note on `knownMismeasured`
                            // in AccessibilityAuditTests.
                            .accessibilityIdentifier("subscription-notice-detail")
                    }
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            // Without .plain, SwiftUI renders the whole label as tinted,
            // centred link text — which reads as a stray hyperlink rather than
            // as the warning card it sits beside on the dashboard.
            .buttonStyle(.plain)
        }
    }
}
#endif
