import Foundation

/// A guest card together with the deadline of the link that unlocked it.
///
/// The expiry is cached alongside the card because the widget extension has no
/// other way to learn it. It never holds the guest token and never calls the
/// server, so without this it would keep rendering a card whose link lapsed
/// days ago — frozen data with nothing on screen to say so.
public struct GuestCachedCard: Codable, Equatable, Sendable {
    public let card: DashboardCard
    public let expiresAt: Date?

    public init(card: DashboardCard, expiresAt: Date?) {
        self.card = card
        self.expiresAt = expiresAt
    }

    public func hasExpired(asOf now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// Cards this device follows through a guest link, in the App Group so the
/// widget extension can render them.
///
/// A separate file from `CardCache` on purpose. The extension refetches the
/// tenant's own cards and overwrites that cache on every refresh, so anything
/// sharing it would be wiped on a schedule nobody controls — and a future write
/// site would reintroduce the bug silently. Two files make that impossible
/// rather than merely unlikely.
public enum GuestCardCache {
    public static func load() -> [GuestCachedCard] {
        guard let data = AppGroup.read(ZeroZeroWidgetConstants.guestCardsCacheFilename) else {
            return []
        }
        return (try? CardCache.jsonDecoder().decode([GuestCachedCard].self, from: data)) ?? []
    }

    public static func save(_ entries: [GuestCachedCard]) throws {
        let data = try CardCache.jsonEncoder().encode(entries)
        try AppGroup.writeAtomic(data, to: ZeroZeroWidgetConstants.guestCardsCacheFilename)
    }

    public static func clear() {
        AppGroup.delete(ZeroZeroWidgetConstants.guestCardsCacheFilename)
    }

    /// Live guest cards with their ids namespaced, ready to sit alongside the
    /// tenant's own.
    ///
    /// Expired entries are dropped here rather than at write time, so a link
    /// lapsing takes its widget down on its own schedule instead of waiting for
    /// somebody to open the app. Ids are namespaced because card ids are unique
    /// per tenant, not globally — a shared "washer" and your own would
    /// otherwise fight over one id in the widget picker.
    public static func namespacedCards(asOf now: Date = Date()) -> [DashboardCard] {
        load()
            .filter { !$0.hasExpired(asOf: now) }
            .map { entry in
                var copy = entry.card
                copy.id = ZeroZeroWidgetConstants.guestCardIdPrefix + entry.card.id
                return copy
            }
    }
}
