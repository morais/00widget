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
                    // A widget added while there were no cards stays
                    // unconfigured. Keep it subscribed so the arrival of its
                    // first card wakes it to show the configuration prompt.
                    subscription.allCards = true
                }
            case ZeroZeroWidgetConstants.WidgetKinds.cardGrid:
                guard let intent = widget.widgetConfigurationIntent(of: SelectGridCardsIntent.self) else {
                    subscription.allCards = true
                    subscriptions[widget.kind] = subscription
                    continue
                }
                let cardIds = intent.selectedCardIds
                subscription.cardIds.append(contentsOf: cardIds)
                if cardIds.isEmpty {
                    // A grid with nothing picked follows the dashboard's
                    // highest-priority cards. Any card can change that set.
                    subscription.allCards = true
                }
            default:
                // A kind this bundle ships but this switch does not describe.
                //
                // Over-subscribe rather than drop it. A widget receiving
                // pushes it did not strictly need spends some of the token's
                // allowance; a widget that registers nothing goes dark and is
                // left with only its timeline — and says so nowhere, which is
                // the worse of the two by a distance.
                //
                // Reached by registering a widget in WidgetBundle and
                // WidgetKinds.all without extending this switch. That step is
                // easy to miss precisely because everything else keeps
                // working: the widget renders, its timeline runs, and only the
                // push path is quietly absent.
                //
                // Kinds outside WidgetKinds.all are not ours to subscribe —
                // the screenshot-only widgets are static, carry no push
                // handler, and must not claim card pushes.
                guard ZeroZeroWidgetConstants.WidgetKinds.all.contains(widget.kind) else {
                    continue
                }
                subscription.allCards = true
                subscriptions[widget.kind] = subscription
                Self.log.warning(
                    "widget kind \(widget.kind, privacy: .public) has no push subscription rule; subscribing to all cards"
                )
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
