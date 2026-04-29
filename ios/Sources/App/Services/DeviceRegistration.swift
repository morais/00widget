import Foundation
import UIKit
import UserNotifications

public enum DeviceRegistration {
    public static func deviceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.deviceId) {
            return existing
        }
        let new = UUID().uuidString
        defaults.set(new, forKey: ZeroZeroWidgetConstants.UserDefaultsKeys.deviceId)
        return new
    }

    public static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    public static func requestNotificationAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    public static func notificationsAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    @MainActor
    public static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
