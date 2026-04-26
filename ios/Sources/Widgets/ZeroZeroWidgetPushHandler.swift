import WidgetKit
import Foundation
import os

/// Receives WidgetKit push tokens from the system (iOS 26+) and hands them
/// to the host app via the App-Group-shared `WidgetPushTokenStore`. The app
/// then registers each token with the backend on next launch — we can't
/// register from the extension itself because the API key lives in the
/// app's Keychain, not the widget's.
struct ZeroZeroWidgetPushHandler: WidgetPushHandler {
    private static let log = Logger(subsystem: "com.example.zerozerowidget", category: "WidgetPush")

    init() {}

    func pushTokenDidChange(_ info: WidgetPushInfo, widgets: [WidgetInfo]) {
        let hex = info.token.map { String(format: "%02x", $0) }.joined()
        for widget in widgets {
            Self.log.info("widget push token for kind=\(widget.kind, privacy: .public)")
            WidgetPushTokenStore.record(widgetKind: widget.kind, pushToken: hex)
        }
    }
}
