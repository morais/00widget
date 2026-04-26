import Foundation

public struct CardCachePayload: Codable, Sendable {
    public var cards: [DashboardCard]
    public var updatedAt: Date

    public init(cards: [DashboardCard], updatedAt: Date = Date()) {
        self.cards = cards
        self.updatedAt = updatedAt
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
            return payload
        }
        if let cards = try? jsonDecoder().decode([DashboardCard].self, from: data) {
            return CardCachePayload(cards: cards)
        }
        return CardCachePayload(cards: [])
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
