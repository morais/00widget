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

    /// Gates Settings → Developer. Fed from the `ZW_DEBUG_TOOLS` build setting,
    /// which is `NO` everywhere except the screenshot run, so shipping builds
    /// never carry the Developer section. A value substituted from a build
    /// setting arrives as a string, not a Bool — hence both branches. Fails
    /// closed on anything unrecognised.
    public static var debugToolsEnabled: Bool {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ZWDebugToolsEnabled") else {
            return false
        }
        if let flag = raw as? Bool { return flag }
        if let text = raw as? String {
            return ["YES", "true", "1"].contains {
                $0.caseInsensitiveCompare(text) == .orderedSame
            }
        }
        return false
    }

    public static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    public static let cardsCacheFilename = "cards.json"
    public static let syncLogFilename = "sync-log.json"

    /// Reserved id prefix for locally generated demo cards and Live Activities.
    /// The prefix is the only signal the app and the widget extension share for
    /// telling samples apart from published state, so `SampleDataFactory` must
    /// keep using it and producers should avoid it.
    public static let sampleCardIdPrefix = "sample-"

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
        public static let hideSampleIndicators = "zw.hideSampleIndicators"
    }

    public enum KeychainKeys {
        public static let apiKey = "zw.apiKey"
        public static let appCredential = "zw.appCredential"
        public static let publisherCredential = "zw.publisherCredential"
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
