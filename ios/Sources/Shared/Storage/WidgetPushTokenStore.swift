import Foundation

public struct WidgetPushSubscription: Codable, Hashable, Sendable {
    public var widgetKind: String
    public var cardIds: [String]
    public var allCards: Bool

    public init(widgetKind: String, cardIds: [String] = [], allCards: Bool = false) {
        self.widgetKind = widgetKind
        self.cardIds = Array(Set(cardIds)).sorted()
        self.allCards = allCards
    }
}

/// Durable bridge between WidgetKit's synchronous token callback and network
/// registration. The callback writes the canonical snapshot first, then both
/// the extension and app can retry it safely.
public enum WidgetPushTokenStore {
    public struct Snapshot: Codable, Equatable, Sendable {
        public var pushToken: String?
        public var subscriptions: [WidgetPushSubscription]
        public var updatedAt: Date
        public var registeredAt: Date?
        public var registeredAppVersion: String?

        public init(
            pushToken: String?,
            subscriptions: [WidgetPushSubscription],
            updatedAt: Date = Date(),
            registeredAt: Date? = nil,
            registeredAppVersion: String? = nil
        ) {
            self.pushToken = pushToken
            self.subscriptions = Self.normalized(subscriptions)
            self.updatedAt = updatedAt
            self.registeredAt = registeredAt
            self.registeredAppVersion = registeredAppVersion
        }

        private static func normalized(
            _ subscriptions: [WidgetPushSubscription]
        ) -> [WidgetPushSubscription] {
            var byKind: [String: WidgetPushSubscription] = [:]
            for subscription in subscriptions {
                let existing = byKind[subscription.widgetKind]
                byKind[subscription.widgetKind] = WidgetPushSubscription(
                    widgetKind: subscription.widgetKind,
                    cardIds: (existing?.cardIds ?? []) + subscription.cardIds,
                    allCards: existing?.allCards == true || subscription.allCards
                )
            }
            return byKind.values
                .filter { $0.allCards || !$0.cardIds.isEmpty }
                .sorted { $0.widgetKind < $1.widgetKind }
        }
    }

    private struct LegacyEntry: Codable {
        var widgetKind: String
        var pushToken: String
        var updatedAt: Date
    }

    private static let filename = "widget-push-tokens.json"
    private static let registrationRefreshInterval: TimeInterval = 24 * 60 * 60

    @discardableResult
    public static func replace(
        pushToken: String?,
        subscriptions: [WidgetPushSubscription]
    ) -> Snapshot {
        var snapshot = Snapshot(pushToken: pushToken, subscriptions: subscriptions)
        if let current = load(),
           current.pushToken == snapshot.pushToken,
           current.subscriptions == snapshot.subscriptions {
            snapshot.registeredAt = current.registeredAt
            snapshot.registeredAppVersion = current.registeredAppVersion
        }
        save(snapshot)
        return snapshot
    }

    public static func load() -> Snapshot? {
        guard let data = AppGroup.read(filename) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            return snapshot
        }
        guard let legacy = try? decoder.decode([LegacyEntry].self, from: data),
              let newest = legacy.max(by: { $0.updatedAt < $1.updatedAt }) else {
            return nil
        }
        return Snapshot(
            pushToken: newest.pushToken,
            subscriptions: legacy
                .filter { $0.pushToken == newest.pushToken }
                .map { WidgetPushSubscription(widgetKind: $0.widgetKind, allCards: true) },
            updatedAt: newest.updatedAt
        )
    }

    public static func needsRegistration(_ snapshot: Snapshot, now: Date = Date()) -> Bool {
        guard snapshot.registeredAppVersion == ZeroZeroWidgetConstants.appVersion else {
            return true
        }
        guard let registeredAt = snapshot.registeredAt else { return true }
        return now.timeIntervalSince(registeredAt) >= registrationRefreshInterval
    }

    public static func markRegistered(_ registered: Snapshot, at date: Date = Date()) {
        guard var current = load(),
              current.pushToken == registered.pushToken,
              current.subscriptions == registered.subscriptions else { return }
        current.registeredAt = date
        current.registeredAppVersion = ZeroZeroWidgetConstants.appVersion
        save(current)
    }

    public static func invalidateRegistration() {
        guard var snapshot = load() else { return }
        snapshot.registeredAt = nil
        snapshot.registeredAppVersion = nil
        save(snapshot)
    }

    public static func clear() {
        AppGroup.delete(filename)
    }

    private static func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? AppGroup.writeAtomic(data, to: filename)
    }
}

public enum WidgetPushTokenRegistrar {
    @discardableResult
    public static func registerCurrent(force: Bool = false) async throws -> Bool {
        guard let snapshot = WidgetPushTokenStore.load() else { return false }
        guard force || WidgetPushTokenStore.needsRegistration(snapshot) else { return true }
        guard let config = APIClientConfig.fromSettings() else { return false }
        try await APIClient(config: config).syncWidgetPushSubscriptions(
            deviceId: SharedSettings.deviceId(),
            widgetPushToken: snapshot.pushToken,
            subscriptions: snapshot.subscriptions
        )
        WidgetPushTokenStore.markRegistered(snapshot)
        return true
    }
}
