import Foundation

/// Bridge for moving WidgetKit push tokens (received in the widget extension's
/// `WidgetPushHandler` callback, iOS 18+) over to the host app, which is the
/// only target that holds the API key and can register them with the backend.
///
/// The widget extension writes — the app reads + re-registers on every launch
/// (re-registration is idempotent on the backend, so we don't bother tracking
/// which tokens have already been sent).
public enum WidgetPushTokenStore {
    public struct Entry: Codable, Hashable, Sendable {
        public var widgetKind: String
        public var pushToken: String
        public var updatedAt: Date

        public init(widgetKind: String, pushToken: String, updatedAt: Date = Date()) {
            self.widgetKind = widgetKind
            self.pushToken = pushToken
            self.updatedAt = updatedAt
        }
    }

    private static let filename = "widget-push-tokens.json"

    public static func record(widgetKind: String, pushToken: String) {
        var entries = load()
        entries.removeAll { $0.widgetKind == widgetKind }
        entries.append(Entry(widgetKind: widgetKind, pushToken: pushToken))
        save(entries)
    }

    public static func load() -> [Entry] {
        guard let data = AppGroup.read(filename) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    public static func clear() {
        AppGroup.delete(filename)
    }

    private static func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? AppGroup.writeAtomic(data, to: filename)
    }
}
