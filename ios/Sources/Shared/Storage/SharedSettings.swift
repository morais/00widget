import Foundation

/// Settings that must resolve to the same value in the app and widget
/// extension processes.
public enum SharedSettings {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ZeroZeroWidgetConstants.appGroupIdentifier)
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
