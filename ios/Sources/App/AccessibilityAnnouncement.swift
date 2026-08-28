import UIKit

/// Posts one explicit outcome for state changes that otherwise only redraw
/// the screen. Keeping this in one place prevents individual flows from
/// mixing speech APIs or accidentally firing duplicate notifications.
@MainActor
enum AccessibilityAnnouncement {
    static func post(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
