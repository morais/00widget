// AppIntents 301.1.16 ships in Xcode 27.2; 301.2.7.2 adds tools in 27.3.
// Runtime availability alone cannot hide unknown macros from the older SDK.
#if canImport(AppIntents, _version: 301.2)
import AppIntents
import Foundation
import SwiftUI

@available(iOS 27.3, *)
extension ShowDashboardIntent: ToolIntent {}
@available(iOS 27.3, *)
extension OpenCardIntent: ToolIntent {}
@available(iOS 27.3, *)
extension CardStatusIntent: ToolIntent {}

@available(iOS 27.3, *)
enum SiriCardFilter: String, AppEnum {
    case all, attention, active, healthy
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Card filter"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "All cards", .attention: "Needs attention", .active: "Active", .healthy: "Healthy"
    ]
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriFindCardsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find published cards"
    static let description = IntentDescription("Fetches current account-owned dashboard cards from the server. Filter by title or status. Returns published observations, not live sensor readings; check each card's last update.")
    @Parameter(title: "Search", description: "Optional words in the card title or subtitle.") var search: String?
    @Parameter(title: "Filter", description: "Which status group to return.", default: .all) var filter: SiriCardFilter

    func perform() async throws -> some IntentResult & ReturnsValue<[DashboardCardEntity]> & ProvidesDialog {
        let cards = try await SiriDashboardService.cards().filter { card in
            let matchesText = search.map { $0.isEmpty || (card.title + " " + (card.subtitle ?? "")).localizedCaseInsensitiveContains($0) } ?? true
            let matchesStatus: Bool
            switch filter {
            case .all: matchesStatus = true
            case .attention: matchesStatus = card.status.needsAttention
            case .active: matchesStatus = card.status.isActive
            case .healthy: matchesStatus = card.status.isHealthy
            }
            return matchesText && matchesStatus
        }
        let answer = cards.isEmpty ? "No matching published cards." : cards.map { CardStatusReport.summary(for: $0) }.joined(separator: ". ")
        return .result(value: cards.map(DashboardCardEntity.init), dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriReadCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Read full card content"
    static let description = IntentDescription("Fetches a card's full current published snapshot, including chart, list, briefing, timeline, available action names, and update time. Use before answering detailed questions, running actions, or preparing an update.")
    @Parameter(title: "Card", description: "The published card to inspect.") var card: DashboardCardEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let current = try await SiriDashboardService.card(id: card.id)
        let json = String(decoding: try CardCache.jsonEncoder().encode(current), as: UTF8.self)
        let answer = CardStatusReport.summary(for: current)
        return .result(value: json, dialog: "\(answer)", view: SiriCardSnippet(card: current))
    }
}

@available(iOS 27.3, *)
enum SiriSimpleTemplate: String, AppEnum {
    case summary, progress, list, chart
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Card template"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .summary: "Summary", .progress: "Progress", .list: "List", .chart: "Chart"
    ]
}

@available(iOS 27.3, *)
@AppEntity(.generable)
struct SiriCardDraft: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "New card content"
    @Property(title: "Title", description: "Short stable name of the card.") var title: String
    @Property(title: "Template", description: "Summary for one value, progress for a fraction, list for several items, chart for numeric history.") var template: SiriSimpleTemplate
    @Property(title: "Subtitle", description: "Optional explanatory text.") var subtitle: String?
    @Property(title: "Value", description: "Optional formatted headline, such as 3.4 or 2 of 5.") var value: String?
    @Property(title: "Unit", description: "Unit belonging to the value, such as kW.") var unit: String?
    @Property(title: "Progress", description: "Optional completion fraction between zero and one.") var progress: Double?
    @Property(title: "Items", description: "List item titles, in order. These are published information, not interactive checklist controls.") var items: [String]?
    @Property(title: "Chart points", description: "Numeric observations in chronological order. Do not invent measurements.") var chartPoints: [Double]?
    @Property(title: "Deadline", description: "Optional deadline for the thing the card describes.") var deadline: Date?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    func document() throws -> PublishingDocument {
        var d = try PublishingDocument(json: "{}")
        d.set("title", title)
        d.set("template", template.rawValue)
        d.set("status", "unknown")
        if let subtitle { d.set("subtitle", subtitle) }
        if let value { d.set("value", value) }
        if let unit { d.set("unit", unit) }
        if let progress { d.fields["progress"] = .number(progress) }
        if let deadline { d.set("deadline", ZeroZeroWidgetDateFormat.iso.string(from: deadline)) }
        if let items {
            d.fields["items"] = .array(items.enumerated().map { i, title in
                .object(["id": .string("item-\(i + 1)"), "title": .string(title)])
            })
        }
        if let chartPoints { d.fields["chart"] = .object(["points": .array(chartPoints.map { .number($0) })]) }
        return d
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriCreateCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a Home Screen dashboard card"
    static let description = IntentDescription("Creates a standing dashboard or Home Screen widget card: summary, progress, list, or chart. For requests mentioning Live Activity, Lock Screen, Dynamic Island, or tracking a break, use Start a Live Activity instead. Uses supplied information; does not establish a data feed.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Content", description: "The card content derived from the person's request.") var content: SiriCardDraft

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let draft = try content.document()
        let json = String(decoding: try CardCache.jsonEncoder().encode(draft), as: UTF8.self)
        let document = try SiriDashboardService.prepareCard(json: json)
        let api = try SiriDashboardService.client(publishing: true)
        let receipt = try await api.publish(document, operation: .card)
        let answer = try SiriDashboardService.receipt(receipt, operation: .card)
        await SiriDashboardService.refreshAfterPublishing()
        return .result(value: document.string("id")!, dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriUpdateCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Update a dashboard card"
    static let description = IntentDescription("Changes supplied fields of an existing dashboard or Home Screen card while preserving other content. For a Live Activity on the Lock Screen or Dynamic Island, use Update a Live Activity instead.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Card", description: "The existing dashboard card to update.") var card: DashboardCardEntity
    @Parameter(title: "Title", description: "New title, only if changing it.") var title: String?
    @Parameter(title: "Subtitle", description: "New subtitle, only if changing it.") var subtitle: String?
    @Parameter(title: "Value", description: "New headline value, only if changing it.") var value: String?
    @Parameter(title: "Unit", description: "New value unit, only if changing it.") var unit: String?
    @Parameter(title: "Progress", description: "New completion fraction between zero and one.") var progress: Double?
    @Parameter(title: "Status", description: "New status: unknown, good, warning, critical, running, finished, paused, or offline.") var status: String?
    @Parameter(title: "List items", description: "Complete replacement of list item titles, only if asked to replace them. Use the advanced card tool for item metadata.") var items: [String]?
    @Parameter(title: "Deadline", description: "New deadline, only if changing it.") var deadline: Date?
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let current = try await SiriDashboardService.card(id: card.id)
        let document = try SiriDashboardService.cardChanges(card: current, title: title, subtitle: subtitle, value: value, unit: unit, progress: progress, status: status, items: items, deadline: deadline)
        try await requestConfirmation(dialog: "Update the dashboard card \(current.title)?")
        guard try await SiriDashboardService.card(id: current.id) == current else {
            throw SiriDashboardService.failure("The card changed while you were reviewing it. Read the new content and try again.")
        }
        let receipt = try await SiriDashboardService.client(publishing: true).publish(document, operation: .card)
        let answer = try SiriDashboardService.receipt(receipt, operation: .card)
        await SiriDashboardService.refreshAfterPublishing()
        return .result(dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriPublishCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Publish complete card content"
    static let description = IntentDescription("Publishes a complete standing dashboard/Home Screen card in any supported template. For Live Activity, Lock Screen, Dynamic Island, or break tracking requests, use Start a Live Activity instead. Supply full public-API card JSON. Omit the existing card to create; select one only for an intentional full replacement.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Existing card", description: "Optional card to replace. Read its full content first; preserve all information and action definitions that should remain.") var card: DashboardCardEntity?
    @Parameter(title: "Content", description: "Complete JSON object with template and title plus public DashboardCard fields. The tool supplies id and updatedAt. Never fabricate webhook IDs, action payloads, or measurements.") var content: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let existing: DashboardCard?
        if let card { existing = try await SiriDashboardService.card(id: card.id) } else { existing = nil }
        // Read responses omit write-only webhook data. Replacing a card that
        // owns actions would destroy those bindings, even if its visible action
        // labels were copied. Keep that operation in the original producer.
        guard existing?.actions?.isEmpty != false else {
            throw SiriDashboardService.failure("This card has producer-owned actions. Ask its producer to update it, or create a separate card.")
        }
        let document = try SiriDashboardService.prepareCard(json: content, replacing: existing)
        if let existing {
            try await requestConfirmation(dialog: "Replace the full content of \(existing.title)?")
            guard try await SiriDashboardService.card(id: existing.id) == existing else {
                throw SiriDashboardService.failure("The card changed while you were reviewing it. Read the new content and try again.")
            }
        }
        let receipt = try await SiriDashboardService.client(publishing: true).publish(document, operation: .card)
        let answer = try SiriDashboardService.receipt(receipt, operation: .card)
        await SiriDashboardService.refreshAfterPublishing()
        return .result(value: document.string("id")!, dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriDeleteCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete a published card"
    static let description = IntentDescription("Deletes an account-owned card from the server and widgets after confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Card", description: "The exact card to delete.") var card: DashboardCardEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let current = try await SiriDashboardService.card(id: card.id)
        try await requestConfirmation(dialog: "Delete \(current.title) from your dashboard and widgets?")
        try await SiriDashboardService.client(publishing: true).deleteCard(id: current.id)
        await SiriDashboardService.refreshAfterPublishing()
        return .result(dialog: "Deleted \(current.title).")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriRunCardActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a published card action"
    static let description = IntentDescription("Runs an action actually published on the selected card. Read the card to discover available labels. Requires confirmation for destructive actions or actions marked for confirmation.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Card", description: "Card that owns the action.") var card: DashboardCardEntity
    @Parameter(title: "Action", description: "Exact published action label, not a guessed action ID.") var action: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let current = try await SiriDashboardService.card(id: card.id)
        let matches = (current.actions ?? []).filter { $0.label.compare(action, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        guard matches.count == 1, let selected = matches.first else {
            throw SiriDashboardService.failure("Choose one of the card's published actions: " + (current.actions ?? []).map(\.label).joined(separator: ", "))
        }
        if !selected.isSafeFromWidget {
            let copy = selected.confirmationPresentation(for: current)
            try await requestConfirmation(dialog: "\(copy.message)")
            // Re-read after the confirmation so a changed action is never run
            // under consent for the definition shown before the prompt.
            let fresh = try await SiriDashboardService.card(id: current.id)
            guard fresh.actions?.contains(selected) == true else {
                throw SiriDashboardService.failure("That action changed. Review it and try again.")
            }
            try await SiriDashboardService.client(confirmedAction: true).runConfirmedAction(id: selected.id, cardId: current.id)
        } else {
            try await SiriDashboardService.client().runAction(id: selected.id, cardId: current.id)
        }
        await SiriDashboardService.refreshAfterPublishing()
        return .result(dialog: "Sent \(selected.label) for \(current.title).")
    }
}

@available(iOS 27.3, *)
struct SiriActivityEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Published Live Activity"
    static let defaultQuery = SiriActivityQuery()
    var id: String
    @Property(title: "Title", description: "Stable name of this activity.") var title: String
    @Property(title: "State", description: "Last published state, including a freshness warning when stale.") var state: String
    @Property(title: "Last updated", description: "Time of the producer's latest published observation.") var updatedAt: Date
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(state)") }
    init(_ session: LiveActivitySession) {
        id = session.id; title = session.title
        state = LiveActivityAccessibilitySummary.summary(for: session)
        updatedAt = session.updatedAt
    }
}

@available(iOS 27.3, *)
struct SiriActivityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SiriActivityEntity] {
        try await sessions().filter { identifiers.contains($0.id) }.map(SiriActivityEntity.init)
    }
    func entities(matching string: String) async throws -> [SiriActivityEntity] {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try await sessions().filter { $0.title.localizedCaseInsensitiveContains(string) }.map(SiriActivityEntity.init)
    }
    func suggestedEntities() async throws -> [SiriActivityEntity] { try await sessions().map(SiriActivityEntity.init) }
    func sessions() async throws -> [LiveActivitySession] {
        try await SiriDashboardService.client().fetchLiveActivities(ownedOnly: true).filter { !$0.isSample }
    }
    func session(id: String) async throws -> LiveActivitySession {
        guard let session = try await sessions().first(where: { $0.id == id }) else {
            throw SiriDashboardService.failure("That activity has ended or is no longer available.")
        }
        return session
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriFindActivitiesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find published Live Activities"
    static let description = IntentDescription("Fetches active published activities from the server, including their current state, progress, and freshness. Use before referring to an activity.")
    func perform() async throws -> some IntentResult & ReturnsValue<[SiriActivityEntity]> & ProvidesDialog {
        let sessions = try await SiriActivityQuery().sessions()
        let answer = sessions.isEmpty ? "No published activities are running." : sessions.map { LiveActivityAccessibilitySummary.summary(for: $0) }.joined(separator: ". ")
        return .result(value: sessions.map(SiriActivityEntity.init), dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriReadActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Read full Live Activity content"
    static let description = IntentDescription("Fetches the latest complete activity snapshot including items, chart, countdown, and available actions.")
    @Parameter(title: "Activity", description: "The current published activity.") var activity: SiriActivityEntity
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let session = try await SiriActivityQuery().session(id: activity.id)
        let json = String(decoding: try CardCache.jsonEncoder().encode(session), as: UTF8.self)
        let answer = LiveActivityAccessibilitySummary.summary(for: session)
        return .result(value: json, dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriStartActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Live Activity"
    static let description = IntentDescription("Creates a Live Activity for the Lock Screen and Dynamic Island. Use when someone asks to track a lunch break, coffee break, study session, workout, countdown, or any bounded task as a Live Activity. This creates a Live Activity, not a dashboard card. Duration and end time are optional; never invent them.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Title", description: "Short stable name, for example Lunch Break.") var title: String
    @Parameter(title: "Subtitle", description: "Optional description of the current activity.") var subtitle: String?
    @Parameter(title: "Duration in minutes", description: "Duration only if the person supplied one. Omit if unknown or an end time was supplied.") var durationMinutes: Double?
    @Parameter(title: "End time", description: "End time only if the person supplied it. Omit when a duration was supplied or unknown.") var endsAt: Date?
    @Parameter(title: "Progress", description: "Known completion fraction between zero and one, or omit.") var progress: Double?
    @Parameter(title: "Value", description: "Optional short headline value.") var value: String?
    @Parameter(title: "Unit", description: "Optional unit belonging to the value.") var unit: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let document = try SiriDashboardService.newActivity(
            title: title, subtitle: subtitle, durationMinutes: durationMinutes,
            endsAt: endsAt, progress: progress, value: value, unit: unit
        )
        let receipt = try await SiriDashboardService.client(publishing: true).publish(document, operation: .startActivity)
        let answer = try SiriDashboardService.receipt(receipt, operation: .startActivity)
        await SiriDashboardService.refreshAfterPublishing()
        return .result(value: document.string("externalActivityId")!, dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriPublishActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Publish advanced Live Activity content"
    static let description = IntentDescription("Starts a Live Activity with advanced JSON content such as composite items, charts, custom kind, signals, and icons. Use Start a Live Activity for ordinary spoken break, countdown, or task tracking requests.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Content", description: "JSON object with title, kind (generic/progress/charging/appliance/job/timer), and state; optional subtitle, value, unit, progress 0...1, items, chart, endsAt ISO8601, countdownGranularity, staleAt, relevanceScore, icon, signal. The tool assigns a new externalActivityId.") var content: String
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let document = try SiriDashboardService.prepareActivity(json: content, operation: .startActivity)
        let receipt = try await SiriDashboardService.client(publishing: true).publish(document, operation: .startActivity)
        let answer = try SiriDashboardService.receipt(receipt, operation: .startActivity)
        await SiriDashboardService.refreshAfterPublishing()
        return .result(value: document.string("externalActivityId")!, dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriUpdateActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Update a Live Activity"
    static let description = IntentDescription("Changes an existing Live Activity on the Lock Screen and Dynamic Island: its state, subtitle, progress, value, or end time. Use for follow-ups about a lunch break, session, or countdown. Preserves all omitted fields. This updates the Live Activity, not a dashboard card.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Activity", description: "The exact running Live Activity to update.") var activity: SiriActivityEntity
    @Parameter(title: "State", description: "New short state, only if changing it.") var state: String?
    @Parameter(title: "Subtitle", description: "New subtitle, only if changing it.") var subtitle: String?
    @Parameter(title: "Progress", description: "New completion fraction between zero and one.") var progress: Double?
    @Parameter(title: "Value", description: "New short headline, only if changing it.") var value: String?
    @Parameter(title: "Unit", description: "New value unit, only if changing it.") var unit: String?
    @Parameter(title: "Duration in minutes", description: "Set an end time this many minutes from now, only if requested. Do not also supply End time.") var durationMinutes: Double?
    @Parameter(title: "End time", description: "New absolute end time, only if requested. Do not also supply Duration in minutes.") var endsAt: Date?
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let current = try await SiriActivityQuery().session(id: activity.id)
        let document = try SiriDashboardService.activityChanges(externalID: current.externalActivityId, state: state, subtitle: subtitle, progress: progress, value: value, unit: unit, durationMinutes: durationMinutes, endsAt: endsAt, existingEndsAt: current.endsAt)
        let receipt = try await SiriDashboardService.client(publishing: true).publish(document, operation: .updateActivity)
        let answer = try SiriDashboardService.receipt(receipt, operation: .updateActivity)
        await SiriDashboardService.refreshAfterPublishing()
        return .result(dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriPublishActivityUpdateIntent: AppIntent {
    static let title: LocalizedStringResource = "Update advanced Live Activity content"
    static let description = IntentDescription("Updates advanced Live Activity fields using partial JSON, including composite items, charts, icons, signals, and explicit nulls to clear fields. Use Update a Live Activity for ordinary spoken state, progress, or timing updates. Cannot change title, kind, or deepLink.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Activity", description: "The exact activity to update.") var activity: SiriActivityEntity
    @Parameter(title: "Changes", description: "Partial public update JSON: state, subtitle, value, unit, progress, items, chart, endsAt, staleAt, icon, signal, countdownGranularity, relevanceScore. No title, kind, or deepLink.") var content: String
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let current = try await SiriActivityQuery().session(id: activity.id)
        let document = try SiriDashboardService.prepareActivity(json: content, operation: .updateActivity, externalID: current.externalActivityId)
        let receipt = try await SiriDashboardService.client(publishing: true).publish(document, operation: .updateActivity)
        let answer = try SiriDashboardService.receipt(receipt, operation: .updateActivity)
        await SiriDashboardService.refreshAfterPublishing()
        return .result(dialog: "\(answer)")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriEndActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "End a published Live Activity"
    static let description = IntentDescription("Ends an activity after confirmation. This removes its presentation; it does not stop the underlying appliance, job, or timer process.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Activity", description: "The exact published activity to end.") var activity: SiriActivityEntity
    @Parameter(title: "Final content", description: "Optional end JSON: finalState, finalSubtitle, finalValue, finalUnit, finalProgress, finalItems, finalChart, finalEndsAt, finalSignal, dismissalDate.") var content: String?
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let current = try await SiriActivityQuery().session(id: activity.id)
        try await requestConfirmation(dialog: "End the Live Activity for \(current.title)? This won't stop the underlying task.")
        _ = try await SiriActivityQuery().session(id: activity.id)
        let document = try SiriDashboardService.prepareActivity(json: content ?? "{}", operation: .endActivity, externalID: current.externalActivityId)
        let receipt = try await SiriDashboardService.client(publishing: true).publish(document, operation: .endActivity)
        _ = try SiriDashboardService.receipt(receipt, operation: .endActivity)
        await SiriDashboardService.refreshAfterPublishing()
        return .result(dialog: "Ended the Live Activity for \(current.title).")
    }
}

@available(iOS 27.3, *)
struct SiriCardSnippet: View {
    let card: DashboardCard
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(card.title, systemImage: card.icon ?? "square.grid.2x2")
                .font(.headline)
            Text(CardStatusReport.summary(for: card))
            Text(card.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriShareCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a read-only card link"
    static let description = IntentDescription("Creates a read-only guest link to one card after confirmation. Anyone holding the link can view that card until the link expires or is revoked. Return the URL for sharing through another app.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Card", description: "The account-owned card to share.") var card: DashboardCardEntity
    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let current = try await SiriDashboardService.card(id: card.id)
        try await requestConfirmation(dialog: "Create a read-only link to \(current.title)? Anyone with the link can view it until it expires or you revoke it.")
        let response = try await SiriDashboardService.client(confirmedAction: true).createGuestLink(resourceKind: "card", resourceId: current.id)
        guard let url = URL(string: response.url) else { throw SiriDashboardService.failure("The server returned an invalid share URL.") }
        return .result(value: url, dialog: "Created a read-only link for \(current.title).")
    }
}

@available(iOS 27.3, *)
@AppIntent(.tool)
struct SiriShareActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a read-only Live Activity link"
    static let description = IntentDescription("Creates a read-only guest link to an owned activity after confirmation. Anyone holding the link can view it until expiry or revocation; the link may also open its App Clip.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Activity", description: "The account-owned activity to share.") var activity: SiriActivityEntity
    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let current = try await SiriActivityQuery().session(id: activity.id)
        guard let instance = current.activityInstanceId else { throw SiriDashboardService.failure("This activity has no server instance to share.") }
        try await requestConfirmation(dialog: "Create a read-only link to \(current.title)? Anyone with the link can view it until it expires or you revoke it.")
        let response = try await SiriDashboardService.client(confirmedAction: true).createGuestLink(resourceKind: "activity", resourceId: instance)
        guard let url = URL(string: response.url) else { throw SiriDashboardService.failure("The server returned an invalid share URL.") }
        return .result(value: url, dialog: "Created a read-only link for \(current.title).")
    }
}
#endif
