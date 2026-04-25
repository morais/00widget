import Foundation

public enum ZeroWidgetConstants {
    public static let appGroupIdentifier = "group.com.example.zerowidget"
    public static let bundleIdentifier = "com.example.zerowidget"

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
