import Foundation

public struct APIClientError: Error, LocalizedError {
    public let status: Int
    public let message: String
    // status 0 means the request never left the device, so an "HTTP" prefix is
    // a lie that sends the reader looking at the server.
    public var errorDescription: String? {
        status == 0 ? message : "HTTP \(status): \(message)"
    }
}

public struct APIClientConfig {
    public var baseURL: URL
    public var apiKey: String

    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public static func fromSettings() -> APIClientConfig? {
        guard
            let url = resolvedBaseURL(),
            let key = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey),
            !key.isEmpty
        else { return nil }
        return APIClientConfig(baseURL: url, apiKey: key)
    }

    /// The server URL alone, with no credential. A guest holds links but may
    /// have no API key at all, so the two have to be resolvable separately.
    public static func resolvedBaseURL() -> URL? {
        let defaults = UserDefaults.standard
        let urlString = SharedSettings.serverBaseURL
            ?? defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL)
            ?? ZeroZeroWidgetConstants.defaultServerBaseURL
        guard !urlString.isEmpty else { return nil }
        return validatedBaseURL(from: urlString)
    }

    public static func validatedBaseURL(from urlString: String) -> URL? {
        guard
            let url = URL(string: urlString),
            let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased(),
            !host.isEmpty
        else { return nil }

        if scheme == "https" {
            return url
        }

        if scheme == "http", isLocalDevelopmentHost(host) {
            return url
        }

        return nil
    }

    private static func isLocalDevelopmentHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }
}

public struct CardsListResponse: Codable {
    public let cards: [DashboardCard]
    public let shared: [DashboardCard]?
}

public struct LiveActivitiesListResponse: Codable {
    public let activities: [LiveActivitySession]
}

public struct DashboardResponse: Codable {
    public let cards: [DashboardCard]
    public let activities: [LiveActivitySession]
}

public struct AppleTokenResponse: Codable {
    public struct Tenant: Codable {
        public let id: String
        public let ownerEmail: String
    }

    public struct APIKey: Codable {
        public let id: String
        public let label: String
    }

    public let tenant: Tenant
    public let apiKey: APIKey
    public let token: String
    public let appCredential: String
    public let publisherCredential: String?
}

/// GET /v1/account. Only the app-only credential can read this, which is why
/// the email it carries never reaches an agent holding a publisher token.
public struct AccountResponse: Codable, Sendable {
    public struct Account: Codable, Sendable {
        public let tenantId: String
        public let ownerEmail: String?
    }

    public let account: Account
}

public struct EmptyBody: Codable {}

public struct SubscriptionVerifyResponse: Codable, Sendable {
    public let subscription: SubscriptionState
    public let accepted: Int
    /// Transactions the server declined — routinely non-empty and not an
    /// error, since StoreKit hands over entitlements from other products too.
    public let rejected: [String]?
}

/// What a guest link unlocks. Exactly one of `card` / `activity` is present,
/// matching `resourceKind`.
public struct GuestResourceResponse: Codable {
    public let resourceKind: String
    public let card: DashboardCard?
    public let activity: LiveActivitySession?
    public let expiresAt: Date?
}

public final class APIClient {
    public let config: APIClientConfig
    public let session: URLSession

    public init(config: APIClientConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// A client authenticated as a guest rather than as this device's tenant.
    /// The guest token goes in the same Authorization header — it is an API
    /// credential, just one whose only scope is reading a single resource.
    public static func guest(baseURL: URL, token: String) -> APIClient {
        APIClient(config: APIClientConfig(baseURL: baseURL, apiKey: token))
    }

    public struct GuestLinkResponse: Codable {
        public let id: String
        public let token: String
        public let url: String
        public let resourceKind: String
        public let resourceId: String
        public let expiresAt: Date
    }

    /// Mints a read-only link for one card or one Live Activity instance.
    /// `resourceKind` is "card" or "activity" — deliberately per instance, not
    /// the coarser kind the email-based sharing feature uses.
    public func createGuestLink(
        resourceKind: String,
        resourceId: String
    ) async throws -> GuestLinkResponse {
        struct Body: Codable {
            let resourceKind: String
            let resourceId: String
        }
        return try await request(
            "POST",
            path: "/v1/shares/guest",
            body: Body(resourceKind: resourceKind, resourceId: resourceId)
        )
    }

    public struct GuestLinkSummary: Codable, Identifiable, Equatable {
        public let id: String
        public let label: String?
        public let resourceKind: String?
        public let resourceId: String?
        public let createdAt: Date?
        public let expiresAt: Date?
        public let lastUsedAt: Date?
    }

    struct GuestLinksListResponse: Codable {
        let links: [GuestLinkSummary]
    }

    /// Links this account has minted and not yet revoked. Never includes the
    /// tokens themselves — they exist only in the response that created them.
    public func listGuestLinks() async throws -> [GuestLinkSummary] {
        let response: GuestLinksListResponse = try await request("GET", path: "/v1/shares/guest")
        return response.links
    }

    public func revokeGuestLink(id: String) async throws {
        let _: EmptyBody = try await request("DELETE", path: "/v1/shares/guest/\(Self.pathSegment(id))")
    }

    public func fetchGuestResource() async throws -> GuestResourceResponse {
        try await request("GET", path: "/v1/guest/resource")
    }

    public func registerGuestActivity(
        deviceId: String,
        localActivityId: String,
        pushToken: String
    ) async throws {
        struct Body: Codable {
            let deviceId: String
            let localActivityId: String
            let pushToken: String
        }
        let _: EmptyBody = try await request(
            "POST",
            path: "/v1/guest/live-activities/register",
            body: Body(deviceId: deviceId, localActivityId: localActivityId, pushToken: pushToken)
        )
    }

    /// Forwards signed StoreKit transactions for the server to verify.
    ///
    /// Every entitlement StoreKit holds, not a filtered set: the server owns
    /// the list of products this deployment sells and reports what it
    /// discarded, so the product list is encoded in exactly one place.
    public func verifySubscription(
        signedTransactions: [String]
    ) async throws -> SubscriptionVerifyResponse {
        struct Body: Codable {
            let signedTransactions: [String]
        }
        return try await request(
            "POST",
            path: "/v1/subscription/verify",
            body: Body(signedTransactions: signedTransactions)
        )
    }

    public func fetchAccount() async throws -> AccountResponse {
        try await request("GET", path: "/v1/account")
    }

    public func subscriptionStatus() async throws -> SubscriptionStatusResponse {
        try await request("GET", path: "/v1/subscription")
    }

    public func health() async throws -> Bool {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("health"))
        req.httpMethod = "GET"
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    public static func createTokenFromApple(
        baseURL: URL,
        identityToken: String,
        rawNonce: String,
        label: String,
        deviceId: String
    ) async throws -> AppleTokenResponse {
        guard APIClientConfig.validatedBaseURL(from: baseURL.absoluteString) != nil else {
            throw APIClientError(status: 0, message: "Server URL must use HTTPS")
        }
        struct Body: Codable {
            let identityToken: String
            let nonce: String
            let label: String
            let deviceId: String
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/auth/apple/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try CardCache.jsonEncoder().encode(
            Body(identityToken: identityToken, nonce: rawNonce, label: label, deviceId: deviceId),
        )

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw APIClientError(status: status, message: message)
        }
        return try CardCache.jsonDecoder().decode(AppleTokenResponse.self, from: data)
    }

    public func fetchCards() async throws -> [DashboardCard] {
        let resp: CardsListResponse = try await request("GET", path: "/v1/cards")
        return resp.cards
    }

    public func fetchCardsIncludingShared() async throws -> (own: [DashboardCard], shared: [DashboardCard]) {
        let resp: CardsListResponse = try await request("GET", path: "/v1/cards?include=shared")
        return (resp.cards, resp.shared ?? [])
    }

    public func fetchLiveActivities() async throws -> [LiveActivitySession] {
        let resp: LiveActivitiesListResponse = try await request(
            "GET",
            path: "/v1/live-activities"
        )
        return resp.activities
    }

    public func fetchDashboard() async throws -> DashboardResponse {
        try await request("GET", path: "/v1/dashboard")
    }

    #if ZW_SHARING_ENABLED
    public struct SharesListResponse: Codable {
        public let shares: [ShareRecord]
    }

    public struct CreateShareResponse: Codable {
        public let share: ShareRecord
    }

    public func createShare(
        recipientEmail: String,
        resourceKind: ShareResourceKind,
        resourceId: String
    ) async throws -> ShareRecord {
        struct Body: Codable {
            let recipientEmail: String
            let resourceKind: String
            let resourceId: String
        }
        let body = Body(
            recipientEmail: recipientEmail,
            resourceKind: resourceKind.rawValue,
            resourceId: resourceId
        )
        let resp: CreateShareResponse = try await request("POST", path: "/v1/shares", body: body)
        return resp.share
    }

    public func listOutgoingShares() async throws -> [ShareRecord] {
        let resp: SharesListResponse = try await request("GET", path: "/v1/shares/outgoing")
        return resp.shares
    }

    public func listIncomingShares() async throws -> [ShareRecord] {
        let resp: SharesListResponse = try await request("GET", path: "/v1/shares/incoming")
        return resp.shares
    }

    public func acceptShare(id: String) async throws {
        let _: EmptyBody = try await request("POST", path: "/v1/shares/\(Self.pathSegment(id))/accept")
    }

    public func declineShare(id: String) async throws {
        let _: EmptyBody = try await request("POST", path: "/v1/shares/\(Self.pathSegment(id))/decline")
    }

    public func revokeShare(id: String) async throws {
        let _: EmptyBody = try await request("DELETE", path: "/v1/shares/\(Self.pathSegment(id))")
    }
    #endif

    public func upsertCard(_ card: DashboardCard) async throws {
        let _: EmptyBody = try await request("POST", path: "/v1/cards/upsert", body: card)
    }

    public func deleteCard(id: String) async throws {
        let _: EmptyBody = try await request("DELETE", path: "/v1/cards/\(Self.pathSegment(id))")
    }

    public func registerDevice(
        deviceId: String,
        apnsDeviceToken: String?,
        appVersion: String,
        platform: String = "ios"
    ) async throws {
        struct Body: Codable {
            let deviceId: String
            let apnsDeviceToken: String?
            let appVersion: String
            let platform: String
        }
        let body = Body(deviceId: deviceId, apnsDeviceToken: apnsDeviceToken, appVersion: appVersion, platform: platform)
        let _: EmptyBody = try await request("POST", path: "/v1/devices/register", body: body)
    }

    public func syncWidgetPushSubscriptions(
        deviceId: String,
        widgetPushToken: String?,
        subscriptions: [WidgetPushSubscription]
    ) async throws {
        struct Body: Codable {
            let deviceId: String
            let widgetPushToken: String?
            let subscriptions: [WidgetPushSubscription]
            let appVersion: String
            let platform: String
        }
        let body = Body(
            deviceId: deviceId,
            widgetPushToken: widgetPushToken,
            subscriptions: subscriptions,
            appVersion: ZeroZeroWidgetConstants.appVersion,
            platform: "ios"
        )
        let _: EmptyBody = try await request(
            "POST",
            path: "/v1/widgets/register-push-token",
            body: body
        )
    }

    public func registerLiveActivity(
        deviceId: String,
        localActivityId: String,
        activityInstanceId: String?,
        externalActivityId: String,
        kind: LiveActivityKind,
        pushToken: String
    ) async throws {
        struct Body: Codable {
            let deviceId: String
            let localActivityId: String
            let activityInstanceId: String?
            let externalActivityId: String
            let kind: String
            let pushToken: String
        }
        let body = Body(
            deviceId: deviceId,
            localActivityId: localActivityId,
            activityInstanceId: activityInstanceId,
            externalActivityId: externalActivityId,
            kind: kind.rawValue,
            pushToken: pushToken
        )
        let _: EmptyBody = try await request("POST", path: "/v1/live-activities/register", body: body)
    }

    public func registerLiveActivityStartToken(
        deviceId: String,
        attributesType: String,
        pushToken: String
    ) async throws {
        struct Body: Codable {
            let deviceId: String
            let attributesType: String
            let pushToken: String
        }
        let body = Body(deviceId: deviceId, attributesType: attributesType, pushToken: pushToken)
        let _: EmptyBody = try await request("POST", path: "/v1/live-activities/register-start-token", body: body)
    }

    public func recoverLiveActivities(
        deviceId: String,
        activityInstanceIds: [String]
    ) async throws {
        struct Body: Codable {
            let deviceId: String
            let activityInstanceIds: [String]
        }
        let body = Body(deviceId: deviceId, activityInstanceIds: activityInstanceIds)
        let _: EmptyBody = try await request(
            "POST",
            path: "/v1/live-activities/recover",
            body: body
        )
    }

    public func runAction(id: String, cardId: String?) async throws {
        struct Context: Codable { let cardId: String? }
        struct Body: Codable {
            let context: Context
        }
        let body = Body(context: Context(cardId: cardId))
        let _: EmptyBody = try await request("POST", path: "/v1/actions/\(Self.pathSegment(id))/run", body: body)
    }

    public func runConfirmedAction(id: String, cardId: String?) async throws {
        struct Context: Codable { let cardId: String? }
        struct Body: Codable { let context: Context }
        let body = Body(context: Context(cardId: cardId))
        let _: EmptyBody = try await request("POST", path: "/v1/actions/\(Self.pathSegment(id))/run-confirmed", body: body)
    }

    public func revokeCurrentCredential() async throws {
        let _: EmptyBody = try await request("DELETE", path: "/v1/auth/token")
    }

    /// Erases the account and everything it holds. App credential only, which
    /// is why callers reach for `confirmedActionClient()` rather than the
    /// device token they use for most requests.
    public func deleteAccount() async throws {
        let _: EmptyBody = try await request("DELETE", path: "/v1/account")
    }

    // MARK: - Internal

    /// Resolves a `/v1/...` path against the configured base URL.
    ///
    /// `appendingPathComponent` cannot do this: it treats the whole string as
    /// one component and escapes what it finds, so `"/v1/cards?include=shared"`
    /// became the literal path `/v1/cards%3Finclude=shared` — a request for a
    /// card whose id is `?include=shared`, which no tenant has. It also
    /// re-escapes the `%` of an already-encoded segment, so a caller cannot
    /// encode an id itself either.
    ///
    /// Building the components explicitly keeps the query a query and leaves
    /// escaped path segments alone. Any base-URL path is preserved, since a
    /// deployment may be mounted under one.
    private func url(for path: String) throws -> URL {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw APIClientError(status: 0, message: "invalid base URL")
        }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let basePath = components.percentEncodedPath
        components.percentEncodedPath =
            (basePath == "/" ? "" : basePath) + String(parts[0])
        components.percentEncodedQuery = parts.count > 1 ? String(parts[1]) : nil
        guard let url = components.url else {
            throw APIClientError(status: 0, message: "invalid request URL")
        }
        return url
    }

    /// Escapes one path segment. Everything outside RFC 3986's unreserved set
    /// is encoded, including `/` — an id carrying one would otherwise become
    /// two segments and address a route that does not exist.
    static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .zwUnreserved) ?? value
    }

    private func request<T: Decodable>(
        _ method: String,
        path: String,
        body: Encodable? = nil
    ) async throws -> T {
        var req = URLRequest(url: try url(for: path))
        req.httpMethod = method
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try CardCache.jsonEncoder().encode(AnyEncodable(body))
        }

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw APIClientError(status: status, message: message)
        }
        if T.self == EmptyBody.self {
            return EmptyBody() as! T
        }
        return try CardCache.jsonDecoder().decode(T.self, from: data)
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved characters. Anything else in a path segment is
    /// percent-encoded, which is what the server now decodes on the way in.
    static let zwUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) {
        self.encodeFunc = { try wrapped.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}
