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

    /// Prefix applied to a card's id when it is written to the widget cache
    /// through a guest link. Two purposes: card ids are unique per tenant, so a
    /// shared card can collide with one of your own, and the rendering layer
    /// needs to know a card is someone else's without a side channel.
    public static let guestCardIdPrefix = "guest-"

    public static let guestCardsCacheFilename = "guest-cards.json"

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
        /// Written by the app, read by the widget extension. See
        /// `SharedSettings.subscriptionActive` for why it defaults to true.
        public static let subscriptionActive = "zw.subscriptionActive"
    }

    public enum KeychainKeys {
        public static let apiKey = "zw.apiKey"
        public static let appCredential = "zw.appCredential"
        public static let publisherCredential = "zw.publisherCredential"
        /// Bearer tokens for resources other people shared with this device.
        /// In the shared access group rather than app-only so the widget
        /// extension could refresh guest cards itself later; today the app
        /// fetches them and writes GuestCardCache, which is what the extension
        /// actually reads.
        public static let guestLinks = "zw.guestLinks"
    }
}

/// Universal links the app claims through its `applinks:` entitlement.
///
/// The path prefix mirrors `UNIVERSAL_LINK_PATH_PREFIX` in
/// `server/src/appleAppSite.ts` — the server decides what it claims, and this
/// side has to agree or links arrive and go nowhere. Keep the two in lockstep.
public enum ZeroZeroWidgetUniversalLink {
    public static let pathPrefix = "/app/"

    /// The in-app route for `url`, or nil when the URL belongs to somebody else
    /// and should open in the browser.
    ///
    /// Host is matched against both the configured server and the build's
    /// default, because the entitlement is pinned to the default host: pointing
    /// the app at a different server must not turn links from the claimed
    /// domain into something the app hands back to iOS.
    public static func route(for url: URL, serverBaseURL: String) -> String? {
        guard
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            url.path.hasPrefix(pathPrefix)
        else {
            return nil
        }
        let claimed = [serverBaseURL, ZeroZeroWidgetConstants.defaultServerBaseURL]
            .compactMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() }
        guard claimed.contains(host) else { return nil }
        return String(url.path.dropFirst(pathPrefix.count))
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
