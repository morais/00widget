import UIKit

/// Posts one explicit outcome for state changes that otherwise only redraw
/// the screen. Keeping this in one place prevents individual flows from
/// mixing speech APIs or accidentally firing duplicate notifications.
///
/// In `Sources/Shared` rather than `Sources/App` because Apple TV needs it
/// too: a television reports an action's outcome by redrawing a dashboard the
/// viewer may not be looking at, which is the same silence this solves on the
/// phone.
@MainActor
enum AccessibilityAnnouncement {
    static func post(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
