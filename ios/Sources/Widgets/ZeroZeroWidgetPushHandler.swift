import WidgetKit
import Foundation
import os

/// Persists WidgetKit's canonical token/configuration snapshot before making a
/// best-effort server registration. The containing app retries the snapshot if
/// the extension is suspended before its network request completes.
struct ZeroZeroWidgetPushHandler: WidgetPushHandler {
    private static let log = Logger(subsystem: "com.example.zerozerowidget", category: "WidgetPush")

    init() {}

    func pushTokenDidChange(_ info: WidgetPushInfo, widgets: [WidgetInfo]) {
        let hex = info.token.map { String(format: "%02x", $0) }.joined()
        let reportedSubscriptions = Self.subscriptions(for: widgets)
        let existing = WidgetPushTokenStore.load()
        let subscriptions: [WidgetPushSubscription]
        if reportedSubscriptions.isEmpty,
           existing?.pushToken == hex,
           let preserved = existing?.subscriptions,
           !preserved.isEmpty {
            // iOS 26 can transiently call this handler with no WidgetInfo
            // even though the widgets remain installed and keep executing.
            // An empty callback is therefore not authoritative removal.
            subscriptions = preserved
            Self.log.warning(
                "widget push callback reported zero widgets; preserving \(preserved.count, privacy: .public) subscription kinds"
            )
        } else {
            subscriptions = reportedSubscriptions
        }
        let snapshot = WidgetPushTokenStore.replace(
            pushToken: hex,
            subscriptions: subscriptions
        )
        Self.log.info(
            "widget push token changed with \(subscriptions.count, privacy: .public) subscription kinds"
        )
        Task {
            do {
                // Send the exact snapshot this callback produced. Reloading
                // the shared file here races startup reconciliation, which can
                // otherwise acknowledge a different subscription set.
                _ = try await WidgetPushTokenRegistrar.register(snapshot)
            } catch {
                Self.log.error(
                    "widget push registration failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func subscriptions(for widgets: [WidgetInfo]) -> [WidgetPushSubscription] {
        var subscriptions: [String: WidgetPushSubscription] = [:]
        for widget in widgets {
            var subscription = subscriptions[widget.kind]
                ?? WidgetPushSubscription(widgetKind: widget.kind)
            switch widget.kind {
            case ZeroZeroWidgetConstants.WidgetKinds.card:
                guard let intent = widget.widgetConfigurationIntent(of: SelectCardIntent.self) else {
                    subscription.allCards = true
                    subscriptions[widget.kind] = subscription
                    continue
                }
                if let cardId = intent.card?.id {
                    if cardId != CardEntityQuery.noneId {
                        subscription.cardIds.append(cardId)
                    }
                } else {
                    // An unconfigured card chooses the first matching card at
                    // render time. Empty here would silently unregister it.
                    subscription.allCards = true
                }
            case ZeroZeroWidgetConstants.WidgetKinds.cardGrid:
                guard let intent = widget.widgetConfigurationIntent(of: SelectFourCardsIntent.self) else {
                    subscription.allCards = true
                    subscriptions[widget.kind] = subscription
                    continue
                }
                let selections = [intent.card1, intent.card2, intent.card3, intent.card4]
                subscription.cardIds.append(contentsOf: selections
                    .compactMap { $0?.id }
                    .filter { $0 != CardEntityQuery.noneId })
                if selections.allSatisfy({ $0 == nil }) {
                    // A grid nobody configured yet fills itself from the
                    // current cache. Any card can change that default set.
                    subscription.allCards = true
                }
            default:
                continue
            }
            subscriptions[widget.kind] = WidgetPushSubscription(
                widgetKind: subscription.widgetKind,
                cardIds: subscription.cardIds,
                allCards: subscription.allCards
            )
        }
        return Array(subscriptions.values)
    }
}
