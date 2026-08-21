import Foundation

/// Settings that must resolve to the same value in the app and widget
/// extension processes.
public enum SharedSettings {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ZeroZeroWidgetConstants.appGroupIdentifier)
    }

    /// Suppresses the "SAMPLE" badges and the "these are samples" notices.
    ///
    /// Exists for the screenshot run: demo data is deliberately labelled in
    /// normal use, but the marketing shots are of the product, not of the
    /// labelling. Off by default and only reachable from Settings → Developer,
    /// which shipping builds do not compile in.
    ///
    /// Falls back to standard defaults because `xcodebuild test` builds with
    /// `CODE_SIGNING_ALLOWED=NO`, which embeds no entitlements and leaves the
    /// App Group container unavailable. In that case only the app process needs
    /// the value; a real build has the container and the widget extension reads
    /// the same flag.
    public static var hideSampleIndicators: Bool {
        (defaults ?? .standard)
            .bool(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.hideSampleIndicators)
    }

    public static func setHideSampleIndicators(_ value: Bool) {
        (defaults ?? .standard)
            .set(value, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.hideSampleIndicators)
    }

    /// Whether the account holds an active subscription.
    ///
    /// Cached here because the widget extension is a separate process that must
    /// not run StoreKit or make network calls of its own, and because widgets
    /// render long after the app last ran. Defaults to true when never written:
    /// a deployment that does not sell subscriptions, or an app that has not
    /// yet asked, must not have its widgets act as though the account lapsed.
    public static var subscriptionActive: Bool {
        let store = defaults ?? .standard
        let key = ZeroZeroWidgetConstants.UserDefaultsKeys.subscriptionActive
        guard store.object(forKey: key) != nil else { return true }
        return store.bool(forKey: key)
    }

    public static func setSubscriptionActive(_ value: Bool) {
        (defaults ?? .standard)
            .set(value, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.subscriptionActive)
    }

    /// Draws the last-render time in the corner of every Home Screen widget,
    /// tinted by what triggered that render. A diagnostic for the one thing
    /// about widgets nobody can otherwise see: when iOS actually redrew them.
    public static var showWidgetTimestamps: Bool {
        (defaults ?? .standard)
            .bool(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.showWidgetTimestamps)
    }

    public static func setShowWidgetTimestamps(_ value: Bool) {
        (defaults ?? .standard)
            .set(value, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.showWidgetTimestamps)
    }

    /// Stamped by the app immediately before every `WidgetCenter` reload
    /// request, and read by the extension while classifying the run that
    /// follows. Deliberately in the App Group rather than passed in the
    /// timeline: the extension is a separate process and there is no other
    /// channel between the reload call and the run it causes.
    public static var lastAppWidgetReloadAt: Date? {
        let value = (defaults ?? .standard)
            .double(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appWidgetReloadAt)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    public static func markAppWidgetReload(at date: Date = Date()) {
        (defaults ?? .standard)
            .set(date.timeIntervalSince1970, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.appWidgetReloadAt)
    }

    public static var serverBaseURL: String? {
        defaults?.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL)
    }

    public static func setServerBaseURL(_ value: String) {
        defaults?.set(value, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.serverBaseURL)
    }

    public static func deviceId() -> String {
        if let existing = defaults?.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.deviceId),
           !existing.isEmpty {
            return existing
        }
        let standard = UserDefaults.standard
        let value = standard.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.deviceId)
            ?? UUID().uuidString
        defaults?.set(value, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.deviceId)
        standard.set(value, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.deviceId)
        return value
    }
}
