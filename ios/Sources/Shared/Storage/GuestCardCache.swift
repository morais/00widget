import Foundation

/// Cards this device follows through a guest link, in the App Group so the
/// widget extension can render them.
///
/// A separate file from `CardCache` on purpose. The extension refetches the
/// tenant's own cards and overwrites that cache on every refresh, so anything
/// sharing it would be wiped on a schedule nobody controls — and a future write
/// site would reintroduce the bug silently. Two files make that impossible
/// rather than merely unlikely.
public enum GuestCardCache {
    public static func load() -> [DashboardCard] {
        guard
            let data = AppGroup.read(ZeroZeroWidgetConstants.guestCardsCacheFilename),
            let cards = try? CardCache.jsonDecoder().decode([DashboardCard].self, from: data)
        else { return [] }
        return cards
    }

    public static func save(_ cards: [DashboardCard]) throws {
        let data = try CardCache.jsonEncoder().encode(cards)
        try AppGroup.writeAtomic(data, to: ZeroZeroWidgetConstants.guestCardsCacheFilename)
    }

    public static func clear() {
        AppGroup.delete(ZeroZeroWidgetConstants.guestCardsCacheFilename)
    }

    /// Guest cards with their ids namespaced, ready to sit alongside the
    /// tenant's own. Ids are unique per tenant, so a shared "washer" and your
    /// own "washer" are different cards that would otherwise fight over one id
    /// in the widget picker.
    public static func namespacedCards() -> [DashboardCard] {
        load().map { card in
            var copy = card
            copy.id = ZeroZeroWidgetConstants.guestCardIdPrefix + card.id
            return copy
        }
    }
}
