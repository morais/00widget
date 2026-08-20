#if ZW_SUBSCRIPTIONS_ENABLED
import Foundation
import StoreKit
import os

#if ZW_SCREENSHOTS
struct SubscriptionScreenshotPlan: Identifiable {
    let id: String
    let displayName: String
    let offerLabel: String?
    let priceLabel: String
}
#endif

/// Buys, restores, and reports the App Store subscription.
///
/// The server is the authority on entitlement, never this class. StoreKit says
/// what this device's App Store account holds; the server decides what this
/// *tenant* is entitled to, having verified the signature and checked the
/// purchase is not already linked elsewhere. So every StoreKit change is
/// forwarded to `/v1/subscription/verify` and the answer is what the UI shows.
///
/// Compiled only when ZW_SUBSCRIPTIONS_ENABLED is in
/// SWIFT_ACTIVE_COMPILATION_CONDITIONS, which no committed configuration sets.
@MainActor
public final class SubscriptionController: ObservableObject {
    private static let log = Logger(
        subsystem: ZeroZeroWidgetConstants.bundleIdentifier,
        category: "Subscription"
    )

    @Published public private(set) var state: SubscriptionState = .none
    @Published public private(set) var products: [Product] = []
    /// Whether this deployment gates publishing at all. Until the server has
    /// answered once, the paywall stays out of the way.
    @Published public private(set) var isRequired = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var purchaseInProgress = false
    @Published public private(set) var lastError: String?
    /// Apple's answer, not ours: someone who has already used a trial is not
    /// eligible for another, and advertising one to them is a lie they will
    /// reasonably report as fraud.
    @Published public private(set) var isEligibleForIntroOffer = false

    private var updatesTask: Task<Void, Never>?
    private var productIds: [String] = []
#if ZW_SCREENSHOTS
    @Published private(set) var screenshotPlans: [SubscriptionScreenshotPlan] = []
#endif

    public init() {}

    deinit {
        updatesTask?.cancel()
    }

    /// Starts the transaction listener and loads current state.
    ///
    /// The listener has to outlive any one screen: a renewal, a refund, or a
    /// purchase completed in the App Store app all arrive through
    /// `Transaction.updates` whenever they happen, including while no paywall
    /// is on screen.
    public func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handle(update)
            }
        }
        Task { await refresh() }
    }

    /// Reads server state, loads products, and forwards anything StoreKit holds.
    public func refresh() async {
        isLoading = true
        defer { isLoading = false }

        #if ZW_SCREENSHOTS
        if let seeded = Self.screenshotState() {
            state = seeded.state
            isRequired = seeded.required
            productIds = seeded.productIds
            prepareScreenshotPlans()
            return
        }
        #endif

        await loadServerState()
        await loadProducts()
        await syncEntitlements()
    }

    #if ZW_SCREENSHOTS
    /// Stands in for the server so the paywall can be photographed without one.
    ///
    /// Compiled only into the screenshot build, like the sample widget kinds —
    /// no shipping build contains it. Plan text is decoded from the same local
    /// .storekit catalog used for manual StoreKit testing, so it cannot drift
    /// from the configured prices and trial periods.
    private static func screenshotState() -> (
        state: SubscriptionState, required: Bool, productIds: [String]
    )? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ZWSubscriptionState"),
              index + 1 < arguments.count
        else { return nil }
        let ids = [
            "com.example.zerozerowidget.monthly",
            "com.example.zerozerowidget.yearly",
        ]
        switch arguments[index + 1] {
        case "none":
            return (.none, true, ids)
        case "expired":
            return (
                SubscriptionState(
                    status: .expired,
                    active: false,
                    productId: ids[0],
                    expiresAt: Date().addingTimeInterval(-6 * 24 * 60 * 60),
                    autoRenew: false
                ),
                true,
                ids
            )
        case "active":
            return (
                SubscriptionState(
                    status: .active,
                    active: true,
                    productId: ids[1],
                    expiresAt: Date().addingTimeInterval(240 * 24 * 60 * 60),
                    autoRenew: true
                ),
                true,
                ids
            )
        default:
            return nil
        }
    }

    private func prepareScreenshotPlans() {
        guard screenshotPlans.isEmpty else { return }
        do {
            guard let url = Bundle.main.url(
                forResource: "ZeroZeroWidget",
                withExtension: "storekit"
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let catalog = try JSONDecoder().decode(
                ScreenshotStoreKitCatalog.self,
                from: Data(contentsOf: url)
            )
            screenshotPlans = catalog.subscriptionGroups
                .flatMap(\.subscriptions)
                .compactMap(Self.screenshotPlan)
                .sorted { $0.priceLabel < $1.priceLabel }
        } catch {
            Self.log.error(
                "screenshot StoreKit catalog failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private struct ScreenshotStoreKitCatalog: Decodable {
        let subscriptionGroups: [Group]

        struct Group: Decodable {
            let subscriptions: [Subscription]
        }

        struct Subscription: Decodable {
            let displayPrice: String
            let introductoryOffer: IntroductoryOffer?
            let localizations: [Localization]
            let productID: String
            let recurringSubscriptionPeriod: String
        }

        struct IntroductoryOffer: Decodable {
            let paymentMode: String
            let subscriptionPeriod: String
        }

        struct Localization: Decodable {
            let displayName: String
            let locale: String
        }
    }

    private static func screenshotPlan(
        _ subscription: ScreenshotStoreKitCatalog.Subscription
    ) -> SubscriptionScreenshotPlan? {
        guard let localization = subscription.localizations.first else { return nil }
        let period: String
        switch subscription.recurringSubscriptionPeriod {
        case "P1M": period = "month"
        case "P1Y": period = "year"
        default: return nil
        }
        let amount = Decimal(string: subscription.displayPrice) ?? 0
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: localization.locale)
        let price = formatter.string(from: NSDecimalNumber(decimal: amount))
            ?? subscription.displayPrice
        let offerLabel = subscription.introductoryOffer.flatMap { offer -> String? in
            guard offer.paymentMode == "free" else { return nil }
            switch offer.subscriptionPeriod {
            case "P1W": return "1 week free, then"
            case "P2W": return "2 weeks free, then"
            case "P1M": return "1 month free, then"
            default: return nil
            }
        }
        return SubscriptionScreenshotPlan(
            id: subscription.productID,
            displayName: localization.displayName,
            offerLabel: offerLabel,
            priceLabel: "\(price) / \(period)"
        )
    }
    #endif

    private func loadServerState() async {
        guard let config = APIClientConfig.fromSettings() else { return }
        do {
            let response = try await APIClient(config: config).subscriptionStatus()
            state = response.subscription
            isRequired = response.required
            productIds = response.productIds
            SharedSettings.setSubscriptionActive(response.subscription.active)
        } catch let error as APIClientError where error.status == 404 {
            // The deployment does not sell subscriptions. Not an error, and the
            // UI should simply not mention them.
            isRequired = false
            state = .none
            SharedSettings.setSubscriptionActive(true)
        } catch {
            Self.log.error("subscription status failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadProducts() async {
        guard !productIds.isEmpty else { return }
        do {
            let loaded = try await Product.products(for: productIds)
            // Cheapest first so monthly leads and the yearly saving reads as an
            // upgrade rather than as the default.
            products = loaded.sorted { $0.price < $1.price }
            if let group = products.first?.subscription {
                isEligibleForIntroOffer = await group.isEligibleForIntroOffer
            }
        } catch {
            Self.log.error("product load failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sends every entitlement StoreKit holds to the server.
    ///
    /// All of them, not just ours: the server is the one that knows which
    /// products this deployment sells, and it reports the ones it discarded
    /// rather than failing. Filtering here would mean two places encoding the
    /// same product list.
    public func syncEntitlements() async {
        var signed: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                signed.append(result.jwsRepresentation)
                _ = transaction
            }
        }
        guard !signed.isEmpty else { return }
        await submit(signed)
    }

    private func submit(_ signedTransactions: [String]) async {
        guard let config = APIClientConfig.fromSettings() else { return }
        do {
            let response = try await APIClient(config: config)
                .verifySubscription(signedTransactions: signedTransactions)
            state = response.subscription
            SharedSettings.setSubscriptionActive(response.subscription.active)
            lastError = nil
        } catch let error as APIClientError where error.status == 404 {
            // Subscriptions are not enabled server-side; nothing to record.
            return
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "Could not verify purchase"
            Self.log.error("verify failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func purchase(_ product: Product) async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        lastError = nil
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
            case .userCancelled:
                break
            case .pending:
                // Ask to Buy, or a payment needing SCA. The entitlement arrives
                // through Transaction.updates whenever it is approved, which
                // may be days later.
                lastError = "Purchase is pending approval."
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// App Review requires this, and so does anyone who reinstalls.
    public func restore() async {
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        do {
            try await AppStore.sync()
            await syncEntitlements()
            await loadServerState()
            if !state.active {
                lastError = "No active subscription was found for this Apple Account."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            // StoreKit could not verify it locally. The server would refuse it
            // too, so there is nothing to send.
            Self.log.error("unverified transaction from StoreKit")
            return
        }
        await submit([result.jwsRepresentation])
        // Only after the server has it: finishing tells StoreKit it never needs
        // to hand this transaction over again.
        await transaction.finish()
    }
}
#endif
