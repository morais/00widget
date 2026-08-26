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

    /// Internal destination used when a full-app Live Activity has no producer
    /// deep link. This key exists in the app's widget extension and is absent
    /// from the App Clip extension, which has no Activities tab.
    public static var liveActivityFallbackURL: URL? {
        guard
            let raw = Bundle.main.object(forInfoDictionaryKey: "ZWLiveActivityFallbackURL") as? String,
            let url = URL(string: raw),
            ZeroZeroWidgetInternalLink.destination(for: url) == .activities
        else {
            return nil
        }
        return url
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

    /// The public pages the app links to.
    ///
    /// One definition because they are shown in two places that answer
    /// different App Store rules: the paywall must carry them (3.1.2, next to
    /// the price, for someone about to be charged) and Settings must carry the
    /// privacy policy (5.1.1, reachable by anyone). A URL that changed in one
    /// place and not the other would leave a broken link on whichever surface
    /// was forgotten.
    public enum Legal {
        public static let privacy = URL(string: "https://00widget.com/privacy")!
        public static let support = URL(string: "https://00widget.com/support")!

        /// Apple's standard EULA. The app licenses under Apple's standard
        /// terms rather than its own, so both the paywall and Settings point
        /// here — the site's Terms of Service is a separate document and is
        /// deliberately not what the app links as its terms.
        public static let terms =
            URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    }

    public enum UserDefaultsKeys {
        public static let serverBaseURL = "zw.serverBaseURL"
        public static let deviceId = "zw.deviceId"
        public static let lastSyncAt = "zw.lastSyncAt"
        public static let lastSyncError = "zw.lastSyncError"
        public static let appleLoginEmail = "zw.appleLoginEmail"
        public static let hideSampleIndicators = "zw.hideSampleIndicators"
        /// Prefix for one record per widget: when its timeline last ran and
        /// what interval it asked for. `WidgetRefreshPolicy` compares the two
        /// to tell a scheduled reload from one a push triggered.
        public static let widgetRefreshRecordPrefix = "zw.widgetRefresh."
        /// Written by the app, read by the widget extension. See
        /// `SharedSettings.subscriptionActive` for why it defaults to true.
        public static let subscriptionActive = "zw.subscriptionActive"
        /// Developer options, both off unless somebody has been through
        /// Settings -> Version. `showWidgetTimestamps` is in the App Group
        /// because the widget extension renders from it; `showRawPayloads` is
        /// app-only and sits alongside it for one place to look.
        public static let showRawPayloads = "zw.showRawPayloads"
        public static let showWidgetTimestamps = "zw.showWidgetTimestamps"
        /// Replaces the account address and the agent token on the Settings
        /// screen with obvious stand-ins, for a screenshot or a shared screen.
        /// App-only, and presentation-only: see `DummyAccountData`.
        public static let showDummyAccountData = "zw.showDummyAccountData"
        /// When the app last asked WidgetKit to reload. Read by the extension
        /// to tell a reload the app requested from one a push delivered — both
        /// arrive ahead of schedule, and they mean different things.
        public static let appWidgetReloadAt = "zw.appWidgetReloadAt"
        /// A small persistent ring buffer written by the widget extension.
        /// Starts are recorded before networking and completions immediately
        /// before the timeline is returned, so a start without a matching
        /// completion proves WidgetKit ran the provider but it never finished.
        public static let widgetTimelineDiagnostics = "zw.widgetTimelineDiagnostics"
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

/// Private navigation URLs emitted by our widget extension, our App Intents,
/// and Spotlight. They are separate from producer-owned HTTPS deep links, which
/// must continue opening externally.
public enum ZeroZeroWidgetInternalLink {
    public static let scheme = "zerozerowidget"

    /// Somewhere inside the app, not merely a tab.
    ///
    /// This started as a bare tab name, which worked while `activities` was the
    /// only destination. A card needs to carry an id as well, and returning
    /// `"card/solar"` where a tab name was expected would have selected a tab
    /// that does not exist — so the destination is modelled and the tab is
    /// derived from it.
    public enum Destination: Equatable, Sendable {
        case activities
        case card(id: String)

        /// Which tab this destination lives on.
        public var tab: String {
            switch self {
            case .activities: return "activities"
            case .card: return "widgets"
            }
        }
    }

    public static func destination(for url: URL) -> Destination? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        switch url.host?.lowercased() {
        case "activities":
            return .activities
        case "card":
            // zerozerowidget://card/<id>. The id is percent-encoded by
            // `cardURL(id:)` because card ids are producer-chosen and the
            // stable-id guidance encourages namespacing them with characters
            // that are not URL-safe.
            let id = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let decoded = id.removingPercentEncoding ?? id
            return decoded.isEmpty ? nil : .card(id: decoded)
        default:
            return nil
        }
    }

    /// The link that opens one card. Shared by `DashboardCardEntity`'s URL
    /// representation and anything else that needs to point at a card, so the
    /// shape lives in one place rather than being spelled out at each site.
    public static func cardURL(id: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard
            !id.isEmpty,
            let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed)
        else {
            return nil
        }
        return URL(string: "\(scheme)://card/\(encoded)")
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
