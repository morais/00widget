import Foundation
import WidgetKit

enum SiriDashboardService {
    static func client(publishing: Bool = false, confirmedAction: Bool = false) throws -> APIClient {
        guard let url = APIClientConfig.resolvedBaseURL() else {
            throw failure("Set up your server in 00Widget Settings first.")
        }
        let key: String?
        if confirmedAction {
            key = KeychainStore.getAppOnly(ZeroZeroWidgetConstants.KeychainKeys.appCredential)
        } else if publishing {
            key = KeychainStore.getAppOnly(ZeroZeroWidgetConstants.KeychainKeys.publisherCredential)
                ?? KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey)
        } else {
            key = KeychainStore.get(ZeroZeroWidgetConstants.KeychainKeys.apiKey)
        }
        guard let key, !key.isEmpty else {
            throw failure("Sign in to 00Widget again in Settings to authorize this device.")
        }
        return APIClient(config: APIClientConfig(baseURL: url, apiKey: key))
    }

    static func failure(_ message: String) -> APIClientError {
        APIClientError(status: 0, message: message)
    }

    static func cards(client: APIClient? = nil) async throws -> [DashboardCard] {
        let api = try client ?? self.client()
        return SpotlightIndex.indexable(try await api.fetchCards())
    }

    static func card(id: String, client: APIClient? = nil) async throws -> DashboardCard {
        guard let card = try await cards(client: client).first(where: { $0.id == id }) else {
            throw failure("That card is no longer published to your account.")
        }
        return card
    }

    static func prepareCard(json: String, replacing: DashboardCard? = nil, now: Date = Date(), newID: String = "siri-" + UUID().uuidString.lowercased()) throws -> PublishingDocument {
        var document = try PublishingDocument(json: json)
        // This is a full replacement, never a guessed patch. Requiring a known
        // template/title also stops the read model's unknown-template fallback
        // from silently turning an invalid publication into a summary card.
        guard let title = document.string("title"), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let template = document.string("template"), DashboardTemplate(rawValue: template) != nil else {
            throw failure("Provide the full card content, including its title and a supported template.")
        }
        document.set("id", replacing?.id ?? newID)
        document.set("updatedAt", ZeroZeroWidgetDateFormat.iso.string(from: now))
        document.fields.removeValue(forKey: "sharedBy")
        if replacing == nil {
            document.fields["producer"] = .object(["label": .string("Siri"), "icon": .string("sparkles")])
        }
        return document
    }

    static func prepareActivity(json: String, operation: APIClient.PublishingOperation, externalID: String? = nil, now: Date = Date(), newID: String = "siri-" + UUID().uuidString.lowercased()) throws -> PublishingDocument {
        var document = try PublishingDocument(json: json)
        document.set("externalActivityId", externalID ?? newID)
        if operation == .startActivity {
            guard let title = document.string("title"), !title.isEmpty,
                  let kind = document.string("kind"), LiveActivityKind.allCases.contains(where: { $0.rawValue == kind }),
                  let state = document.string("state"), !state.isEmpty else {
                throw failure("A new activity needs a title, supported kind, and state.")
            }
        } else if operation == .updateActivity {
            guard document.fields["title"] == nil, document.fields["kind"] == nil, document.fields["deepLink"] == nil else {
                throw failure("An activity's title, kind, and link cannot change after it starts.")
            }
        }
        if operation != .endActivity, document.fields["staleAt"] == nil {
            document.set("staleAt", ZeroZeroWidgetDateFormat.iso.string(from: now.addingTimeInterval(15 * 60)))
        }
        return document
    }

    /// Typed entry point for ordinary spoken requests. Keeping timing here
    /// makes the generated payload testable on the older SDK too.
    static func newActivity(
        title: String, subtitle: String? = nil, durationMinutes: Double? = nil,
        endsAt: Date? = nil, progress: Double? = nil, value: String? = nil,
        unit: String? = nil, now: Date = Date()
    ) throws -> PublishingDocument {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("Give the Live Activity a name.")
        }
        if let durationMinutes, !durationMinutes.isFinite || durationMinutes <= 0 || durationMinutes > 8 * 60 {
            throw failure("A Live Activity duration must be greater than zero and no more than eight hours.")
        }
        guard durationMinutes == nil || endsAt == nil else {
            throw failure("Provide a duration or an end time, not both.")
        }
        let end = endsAt ?? durationMinutes.map { now.addingTimeInterval($0 * 60) }
        if let end, end <= now || end.timeIntervalSince(now) > 8 * 3600 {
            throw failure("The Live Activity must end in the next eight hours.")
        }
        if let progress, !progress.isFinite || !(0...1).contains(progress) {
            throw failure("Progress must be between zero and one.")
        }
        var document = try PublishingDocument(json: "{}")
        document.set("title", title)
        document.set("kind", end == nil ? "generic" : "timer")
        document.set("state", "running")
        if let subtitle { document.set("subtitle", subtitle) }
        if let value { document.set("value", value) }
        if let unit { document.set("unit", unit) }
        if let progress { document.fields["progress"] = .number(progress) }
        if let end {
            document.set("endsAt", ZeroZeroWidgetDateFormat.iso.string(from: end))
            // A countdown is valid through its end without any producer ticks.
            document.set("staleAt", ZeroZeroWidgetDateFormat.iso.string(from: end))
        }
        return try prepareActivity(
            json: String(decoding: CardCache.jsonEncoder().encode(document), as: UTF8.self),
            operation: .startActivity, now: now
        )
    }

    static func activityChanges(
        externalID: String, state: String? = nil, subtitle: String? = nil,
        progress: Double? = nil, value: String? = nil, unit: String? = nil,
        durationMinutes: Double? = nil, endsAt: Date? = nil,
        existingEndsAt: Date? = nil, now: Date = Date()
    ) throws -> PublishingDocument {
        guard state != nil || subtitle != nil || progress != nil || value != nil || unit != nil || durationMinutes != nil || endsAt != nil else {
            throw failure("Specify what to change in the Live Activity.")
        }
        // Reuse timing/range validation without turning the patch into a start.
        let timing = try newActivity(title: "Update", durationMinutes: durationMinutes, endsAt: endsAt, progress: progress, now: now)
        var document = try PublishingDocument(json: "{}")
        if let state { document.set("state", state) }
        if let subtitle { document.set("subtitle", subtitle) }
        if let value { document.set("value", value) }
        if let unit { document.set("unit", unit) }
        if let progress { document.fields["progress"] = .number(progress) }
        if let end = timing.string("endsAt") {
            document.set("endsAt", end)
            document.set("staleAt", end)
        } else if let existingEndsAt, existingEndsAt > now {
            document.set("staleAt", ZeroZeroWidgetDateFormat.iso.string(from: existingEndsAt))
        }
        return try prepareActivity(
            json: String(decoding: CardCache.jsonEncoder().encode(document), as: UTF8.self),
            operation: .updateActivity, externalID: externalID, now: now
        )
    }

    static func cardChanges(
        card: DashboardCard, title: String? = nil, subtitle: String? = nil,
        value: String? = nil, unit: String? = nil, progress: Double? = nil,
        status: String? = nil, items: [String]? = nil, deadline: Date? = nil
    ) throws -> PublishingDocument {
        guard card.actions?.isEmpty != false else {
            throw failure("This card has producer-owned actions. Ask its producer to update it, or create a separate card.")
        }
        guard title != nil || subtitle != nil || value != nil || unit != nil || progress != nil || status != nil || items != nil || deadline != nil else {
            throw failure("Specify what to change in the dashboard card.")
        }
        if let progress, !progress.isFinite || !(0...1).contains(progress) {
            throw failure("Progress must be between zero and one.")
        }
        if let status, DashboardStatus(rawValue: status) == nil {
            throw failure("Use a supported card status: unknown, good, warning, critical, running, finished, paused, or offline.")
        }
        var document = try PublishingDocument(json: String(decoding: CardCache.jsonEncoder().encode(card), as: UTF8.self))
        if let title { document.set("title", title) }
        if let subtitle { document.set("subtitle", subtitle) }
        if let value { document.set("value", value) }
        if let unit { document.set("unit", unit) }
        if let status { document.set("status", status) }
        if let progress { document.fields["progress"] = .number(progress) }
        if let deadline { document.set("deadline", ZeroZeroWidgetDateFormat.iso.string(from: deadline)) }
        if let items {
            guard card.template == .list else { throw failure("Only a list card can have its item titles replaced with this tool.") }
            guard Set(items).count == items.count else {
                throw failure("Use the advanced card tool with item IDs to distinguish repeated list titles.")
            }
            let updated: [DashboardItem] = try items.map { title in
                let matches = (card.items ?? []).filter { $0.title == title }
                guard matches.count <= 1 else {
                    throw failure("Use the advanced card tool with item IDs to distinguish repeated list titles.")
                }
                // Adding or reordering titles must not erase existing item
                // values, status, semantics, links, or stable identities.
                return matches.first ?? DashboardItem(id: "siri-item-" + UUID().uuidString.lowercased(), title: title)
            }
            let encoded = try PublishingDocument(json: "{\"items\":" + String(decoding: CardCache.jsonEncoder().encode(updated), as: UTF8.self) + "}")
            document.fields["items"] = encoded.fields["items"]
        }
        return try prepareCard(
            json: String(decoding: CardCache.jsonEncoder().encode(document), as: UTF8.self), replacing: card
        )
    }

    static func receipt(_ receipt: PublishingDocument, operation: APIClient.PublishingOperation) throws -> String {
        if operation == .card {
            guard case .object = receipt.fields["card"] else {
                throw failure("The server did not return the published card.")
            }
        } else {
            guard case .bool(true) = receipt.fields["ok"] else {
                throw failure("The server did not confirm the publication.")
            }
        }
        var message = operation == .card ? "Dashboard card published." : "Live Activity request accepted."
        if case .number(0) = receipt.fields["pushToStartAttempted"] {
            message += " No device has registered for push-to-start. Open 00Widget on your iPhone and enable notifications."
        } else if case .bool(true) = receipt.fields["pending"] {
            message += " Waiting for a device to register the activity."
        }
        if case .bool(true) = receipt.fields["pendingUpdated"] {
            message += " The update is stored, but no device has registered an activity push token yet."
        }
        if case .array(let warnings) = receipt.fields["warnings"], !warnings.isEmpty {
            let messages = warnings.compactMap { value -> String? in
                guard case .object(let object) = value, case .string(let message) = object["message"] else { return nil }
                return message
            }
            message += " " + messages.joined(separator: " ")
        }
        return message
    }

    @MainActor
    static func refreshAfterPublishing() async {
        // A successful server write remains successful if local refresh fails.
        // Don't replace tenant-owned cache entries with the guest/share view.
        guard let own = try? await cards() else { return }
        try? CardCache.save(own)
        SpotlightIndex.donate(own)
        WidgetCenter.shared.reloadAllTimelines()
        await IntentLanding.refreshPublishedState()
        await LiveActivityController.shared.reconcileWithServer()
    }
}
