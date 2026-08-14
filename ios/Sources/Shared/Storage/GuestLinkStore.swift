import Foundation

/// Persists the guest links this device holds.
///
/// Tokens are bearer credentials, so they live in the Keychain rather than the
/// App Group's UserDefaults — but in the *shared* access group, because the
/// widget extension renders guest cards in the same views as owned ones and
/// needs to read them too.
///
/// Stored as one JSON blob under a single key. The list is small by nature (a
/// person holds a handful of shared links, not thousands) and a single item
/// keeps the read atomic, which matters when the app and the extension can
/// both be running.
public enum GuestLinkStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func load() -> [GuestLink] {
        guard
            let raw = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.guestLinks),
            let data = raw.data(using: .utf8),
            let links = try? decoder.decode([GuestLink].self, from: data)
        else { return [] }
        return links
    }

    public static func save(_ links: [GuestLink]) {
        guard
            let data = try? encoder.encode(links),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        try? KeychainStore.set(raw, for: ZeroZeroWidgetConstants.KeychainKeys.guestLinks)
    }

    /// Adds a link, replacing any existing entry for the same token so scanning
    /// the same code twice does not produce a duplicate row.
    @discardableResult
    public static func add(_ link: GuestLink) -> [GuestLink] {
        var links = load().filter { $0.token != link.token }
        links.append(link)
        save(links)
        return links
    }

    @discardableResult
    public static func remove(token: String) -> [GuestLink] {
        let links = load().filter { $0.token != token }
        save(links)
        return links
    }

    public static func removeAll() {
        KeychainStore.delete(ZeroZeroWidgetConstants.KeychainKeys.guestLinks)
    }
}
