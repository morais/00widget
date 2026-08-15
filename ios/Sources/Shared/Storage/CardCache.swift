import Foundation

public struct CardCachePayload: Codable, Sendable {
    public static let currentSchemaVersion = 2

    public var cards: [DashboardCard]
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        cards: [DashboardCard],
        updatedAt: Date = Date(),
        schemaVersion: Int = CardCachePayload.currentSchemaVersion
    ) {
        self.cards = cards
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cards = try container.decode([DashboardCard].self, forKey: .cards)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}

public enum CardCache {
    public static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self),
               let date = ZeroZeroWidgetDateFormat.parse(s) {
                return date
            }
            if let t = try? c.decode(TimeInterval.self) {
                return Date(timeIntervalSince1970: t)
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date")
        }
        return d
    }

    public static func load() -> CardCachePayload {
        guard let data = AppGroup.read(ZeroZeroWidgetConstants.cardsCacheFilename) else {
            return CardCachePayload(cards: [])
        }
        if let payload = try? jsonDecoder().decode(CardCachePayload.self, from: data) {
            if payload.schemaVersion < CardCachePayload.currentSchemaVersion {
                // Decoding through the current public model drops legacy
                // write-only fields such as action payloads. Rewrite once so
                // their raw bytes no longer remain in the App Group cache.
                try? save(payload.cards)
                return CardCachePayload(cards: payload.cards, updatedAt: payload.updatedAt)
            }
            return payload
        }
        if let cards = try? jsonDecoder().decode([DashboardCard].self, from: data) {
            try? save(cards)
            return CardCachePayload(cards: cards)
        }
        return CardCachePayload(cards: [])
    }

    /// Everything the widget layer should offer: the tenant's own cards plus
    /// any followed through a guest link, the latter namespaced so a shared
    /// card and one of your own cannot collide on id.
    public static func cardsForWidgets() -> [DashboardCard] {
        load().cards + GuestCardCache.namespacedCards()
    }

    public static func save(_ cards: [DashboardCard]) throws {
        let payload = CardCachePayload(cards: cards)
        let data = try jsonEncoder().encode(payload)
        try AppGroup.writeAtomic(data, to: ZeroZeroWidgetConstants.cardsCacheFilename)
    }

    public static func card(withId id: String) -> DashboardCard? {
        load().cards.first { $0.id == id }
    }

    public static func clear() {
        AppGroup.delete(ZeroZeroWidgetConstants.cardsCacheFilename)
    }
}
