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
