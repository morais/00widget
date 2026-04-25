import Foundation

public enum ZeroWidgetConstants {
    /// The App Group identifier shared between the app and widget targets.
    ///
    /// The value comes from the `ZWAppGroupIdentifier` key in each target's
    /// `Info.plist`, which `project.yml` writes from a single source. The
    /// fallback is the public placeholder so the app still launches against
    /// the unedited project.yml.sample.
    public static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "ZWAppGroupIdentifier") as? String
            ?? "group.com.example.zerowidget"
    }

    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.example.zerowidget"
    }

    public static let cardsCacheFilename = "cards.json"
    public static let syncLogFilename = "sync-log.json"

    public enum WidgetKinds {
        public static let metric = "ZeroWidgetMetricWidget"
        public static let status = "ZeroWidgetStatusWidget"
        public static let list = "ZeroWidgetListWidget"
        public static let progress = "ZeroWidgetProgressWidget"

        public static let all: [String] = [metric, status, list, progress]
    }

    public enum UserDefaultsKeys {
        public static let serverBaseURL = "zw.serverBaseURL"
        public static let deviceId = "zw.deviceId"
        public static let lastSyncAt = "zw.lastSyncAt"
        public static let lastSyncError = "zw.lastSyncError"
    }

    public enum KeychainKeys {
        public static let apiKey = "zw.apiKey"
    }
}
