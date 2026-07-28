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
        let subscriptions = Self.subscriptions(for: widgets)
        WidgetPushTokenStore.replace(pushToken: hex, subscriptions: subscriptions)
        Self.log.info(
            "widget push token changed with \(subscriptions.count, privacy: .public) subscription kinds"
        )
        Task {
            do {
                _ = try await WidgetPushTokenRegistrar.registerCurrent()
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
                if let cardId = intent.card?.id, cardId != CardEntityQuery.noneId {
                    subscription.cardIds.append(cardId)
                } else if intent.statusFilter != .all {
                    // A status-filtered widget without a pinned card chooses a
                    // matching card dynamically, so every card can affect it.
                    subscription.allCards = true
                }
            case ZeroZeroWidgetConstants.WidgetKinds.cardGrid:
                guard let intent = widget.widgetConfigurationIntent(of: SelectFourCardsIntent.self) else {
                    subscription.allCards = true
                    subscriptions[widget.kind] = subscription
                    continue
                }
                subscription.cardIds.append(
                    contentsOf: [intent.card1, intent.card2, intent.card3, intent.card4]
                        .compactMap { $0?.id }
                        .filter { $0 != CardEntityQuery.noneId }
                )
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
