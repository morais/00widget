import Foundation

/// What the server believes about this account's App Store subscription.
///
/// Mirrors `SubscriptionState` in `server/src/subscription.ts`. Keep the two in
/// lockstep — see the data model note in AGENTS.md.
///
/// Compiled unconditionally, unlike the rest of the subscription code, because
/// `SharedSettings` caches the entitlement for the widget extension and a
/// stored value whose type disappears with a build flag is a migration problem
/// waiting to happen.
public struct SubscriptionState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case none
        case active
        case trial
        /// Lapsed but still honoured: Apple's billing grace period, or the
        /// server's own window covering a late notification.
        case grace
        case expired
        /// Refunded. Outranks any expiry date still on the record.
        case revoked

        /// Unknown values decode to `.none` rather than failing. A server that
        /// has learned a new status must not make an older app unable to read
        /// its own entitlement.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .none
        }
    }

    public let status: Status
    /// The server's decision, not something to recompute on device. Grace
    /// windows and refunds both make "active" more than a date comparison.
    public let active: Bool
    public let productId: String?
    public let expiresAt: Date?
    public let autoRenew: Bool?
    public let environment: String?

    public init(
        status: Status,
        active: Bool,
        productId: String? = nil,
        expiresAt: Date? = nil,
        autoRenew: Bool? = nil,
        environment: String? = nil
    ) {
        self.status = status
        self.active = active
        self.productId = productId
        self.expiresAt = expiresAt
        self.autoRenew = autoRenew
        self.environment = environment
    }

    public static let none = SubscriptionState(status: .none, active: false)

    /// Whether the account is in a state the person should be told about.
    /// A trial nearing its end is not a problem; a lapse is.
    public var needsAttention: Bool {
        switch status {
        case .grace, .expired, .revoked: return true
        case .none, .active, .trial: return false
        }
    }
}

/// The server's answer to `GET /v1/subscription`.
public struct SubscriptionStatusResponse: Codable, Sendable {
    public let subscription: SubscriptionState
    /// Whether this deployment gates publishing. The app cannot infer it:
    /// having no entitlement means something different where writes are gated
    /// than where they are not.
    public let required: Bool
    public let productIds: [String]
}
