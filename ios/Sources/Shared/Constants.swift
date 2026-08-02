import Foundation

public enum ZeroZeroWidgetConstants {
    /// The App Group identifier shared between the app and widget targets.
    ///
    /// The value comes from the `ZWAppGroupIdentifier` key in each target's
    /// `Info.plist`, which `project.yml` writes from a single source. The
    /// fallback is the public placeholder so the app still launches against
    /// the unedited project.yml.sample.
    public static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "ZWAppGroupIdentifier") as? String
            ?? "group.com.example.zerozerowidget"
    }

    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.example.zerozerowidget"
    }

    public static var defaultServerBaseURL: String {
        Bundle.main.object(forInfoDictionaryKey: "ZWDefaultServerBaseURL") as? String ?? ""
    }

    public static var appleLoginEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ZWAppleLoginEnabled") as? Bool ?? false
    }

    public static var debugTabEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ZWDebugTabEnabled") as? Bool ?? true
    }

    public static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    public static let cardsCacheFilename = "cards.json"
    public static let syncLogFilename = "sync-log.json"

    public enum WidgetKinds {
        public static let card = "ZeroZeroWidgetCardWidget"
        public static let cardGrid = "ZeroZeroWidgetCardGridWidget"

        public static let all: [String] = [card, cardGrid]
    }

    public enum UserDefaultsKeys {
        public static let serverBaseURL = "zw.serverBaseURL"
        public static let deviceId = "zw.deviceId"
        public static let lastSyncAt = "zw.lastSyncAt"
        public static let lastSyncError = "zw.lastSyncError"
        public static let appleLoginEmail = "zw.appleLoginEmail"
    }

    public enum KeychainKeys {
        public static let apiKey = "zw.apiKey"
    }
}

public enum ZeroZeroWidgetDeepLinkPolicy {
    public static func sanitize(_ url: URL?) -> URL? {
        guard
            let url,
            url.scheme?.lowercased() == "https",
            let host = url.host,
            !host.isEmpty
        else {
            return nil
        }
        return url
    }
}
