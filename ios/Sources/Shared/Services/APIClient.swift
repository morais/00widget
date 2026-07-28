import Foundation

public struct APIClientError: Error, LocalizedError {
    public let status: Int
    public let message: String
    public var errorDescription: String? { "HTTP \(status): \(message)" }
}

public struct APIClientConfig {
    public var baseURL: URL
    public var apiKey: String

    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public static func fromSettings() -> APIClientConfig? {
        let defaults = UserDefaults.standard
        let urlString = SharedSettings.serverBaseURL
            ?? defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL)
            ?? ZeroZeroWidgetConstants.defaultServerBaseURL
        guard
            !urlString.isEmpty,
            let url = validatedBaseURL(from: urlString),
            let key = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey),
            !key.isEmpty
        else { return nil }
        return APIClientConfig(baseURL: url, apiKey: key)
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
}

public struct EmptyBody: Codable {}

public final class APIClient {
    public let config: APIClientConfig
    public let session: URLSession

    public init(config: APIClientConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
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
        label: String
    ) async throws -> AppleTokenResponse {
        guard APIClientConfig.validatedBaseURL(from: baseURL.absoluteString) != nil else {
            throw APIClientError(status: 0, message: "Server URL must use HTTPS")
        }
        struct Body: Codable {
            let identityToken: String
            let nonce: String
            let label: String
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/auth/apple/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try CardCache.jsonEncoder().encode(
            Body(identityToken: identityToken, nonce: rawNonce, label: label),
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
        let _: EmptyBody = try await request("POST", path: "/v1/shares/\(id)/accept")
    }

    public func declineShare(id: String) async throws {
        let _: EmptyBody = try await request("POST", path: "/v1/shares/\(id)/decline")
    }

    public func revokeShare(id: String) async throws {
        let _: EmptyBody = try await request("DELETE", path: "/v1/shares/\(id)")
    }
    #endif

    public func upsertCard(_ card: DashboardCard) async throws {
        let _: EmptyBody = try await request("POST", path: "/v1/cards/upsert", body: card)
    }

    public func deleteCard(id: String) async throws {
        let _: EmptyBody = try await request("DELETE", path: "/v1/cards/\(id)")
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
        }
        let body = Body(
            deviceId: deviceId,
            widgetPushToken: widgetPushToken,
            subscriptions: subscriptions
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
        externalActivityId: String,
        kind: LiveActivityKind,
        pushToken: String
    ) async throws {
        struct Body: Codable {
            let deviceId: String
            let localActivityId: String
            let externalActivityId: String
            let kind: String
            let pushToken: String
        }
        let body = Body(
            deviceId: deviceId,
            localActivityId: localActivityId,
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

    public func runAction(id: String, cardId: String?, source: String) async throws {
        struct Context: Codable { let cardId: String? }
        struct Body: Codable {
            let source: String
            let context: Context
        }
        let body = Body(source: source, context: Context(cardId: cardId))
        let _: EmptyBody = try await request("POST", path: "/v1/actions/\(id)/run", body: body)
    }

    // MARK: - Internal

    private func request<T: Decodable>(
        _ method: String,
        path: String,
        body: Encodable? = nil
    ) async throws -> T {
        var req = URLRequest(url: config.baseURL.appendingPathComponent(path))
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

struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) {
        self.encodeFunc = { try wrapped.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}
