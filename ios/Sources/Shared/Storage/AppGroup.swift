import Foundation
import os

public enum AppGroup {
    public static let identifier = ZeroWidgetConstants.appGroupIdentifier

    private static let log = Logger(subsystem: "com.example.zerowidget", category: "AppGroup")

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static func fileURL(for name: String) -> URL? {
        containerURL?.appendingPathComponent(name, conformingTo: .json)
    }

    public static var isAvailable: Bool {
        containerURL != nil
    }

    public static func writeAtomic(_ data: Data, to name: String) throws {
        guard let url = fileURL(for: name) else {
            throw NSError(domain: "AppGroup", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable"])
        }
        try data.write(to: url, options: [.atomic])
    }

    public static func read(_ name: String) -> Data? {
        guard let url = fileURL(for: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func delete(_ name: String) {
        guard let url = fileURL(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
