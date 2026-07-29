import Foundation
import UIKit
import UserNotifications

public enum DeviceRegistration {
    public static func deviceId() -> String {
        SharedSettings.deviceId()
    }

    public static func appVersion() -> String {
        ZeroZeroWidgetConstants.appVersion
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

    public static func notificationsDenied() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .denied
    }

    @MainActor
    public static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
