import Foundation
import Testing
@testable import ZeroZeroWidgetApp

@Suite("Siri publishing contract")
struct SiriPublishingTests {
    @Test("Creation ignores a supplied identity and preserves complex content")
    func newIdentityAndContent() throws {
        let document = try SiriDashboardService.prepareCard(
            json: #"{"id":"someone-elses-card","template":"briefing","title":"Build report","briefing":{"sections":[{"id":"cause","text":"All checks passed"}]},"actions":[{"id":"ack","label":"Acknowledge","webhookId":"actual-producer-id","payload":{"job":42}}],"sharedBy":{"ownerEmail":"other@example.com"}}"#,
            now: Date(timeIntervalSince1970: 0), newID: "siri-created"
        )
        let object = try #require(JSONSerialization.jsonObject(with: CardCache.jsonEncoder().encode(document)) as? [String: Any])
        #expect(object["id"] as? String == "siri-created")
        #expect(object["sharedBy"] == nil)
        #expect(object["briefing"] is [String: Any])
        let action = try #require((object["actions"] as? [[String: Any]])?.first)
        #expect(action["webhookId"] as? String == "actual-producer-id")
        #expect((action["payload"] as? [String: Int])?["job"] == 42)
    }

    @Test("Replacement pins identity to the selected card")
    func replacementIdentity() throws {
        let card = DashboardCard(id: "selected", template: .summary, title: "Current")
        let document = try SiriDashboardService.prepareCard(
            json: #"{"id":"wrong","template":"summary","title":"Updated"}"#, replacing: card
        )
        #expect(document.string("id") == "selected")
    }

    @Test("Invalid or partial cards cannot be published as complete replacements")
    func invalidCard() {
        for json in ["[]", #"{"title":"Missing template"}"#, #"{"template":"made-up","title":"Unsupported"}"#, #"{"template":"summary","title":" "}"#] {
            #expect(throws: (any Error).self) { try SiriDashboardService.prepareCard(json: json) }
        }
    }

    @Test("Activity patches preserve explicit nulls and omitted fields")
    func activityPatch() throws {
        let document = try SiriDashboardService.prepareActivity(
            json: #"{"externalActivityId":"wrong","progress":0.5,"endsAt":null,"items":[]}"#,
            operation: .updateActivity, externalID: "selected", now: Date(timeIntervalSince1970: 0)
        )
        let object = try #require(JSONSerialization.jsonObject(with: CardCache.jsonEncoder().encode(document)) as? [String: Any])
        #expect(object["externalActivityId"] as? String == "selected")
        #expect(object["endsAt"] is NSNull)
        #expect(object["subtitle"] == nil)
        #expect(object["progress"] as? Double == 0.5)
        #expect(object["staleAt"] as? String == "1970-01-01T00:15:00.000Z")
    }

    @Test("Updates cannot pretend to change frozen activity attributes")
    func frozenAttributes() {
        for key in ["title", "kind", "deepLink"] {
            #expect(throws: APIClientError.self) {
                try SiriDashboardService.prepareActivity(json: "{\"\(key)\":\"new\"}", operation: .updateActivity, externalID: "selected")
            }
        }
    }

    @Test("End payloads preserve final state and do not create a stale date")
    func finalFrame() throws {
        let document = try SiriDashboardService.prepareActivity(
            json: #"{"finalState":"finished","finalProgress":1}"#, operation: .endActivity, externalID: "run"
        )
        #expect(document.string("finalState") == "finished")
        #expect(document.fields["staleAt"] == nil)
    }

    @Test("A stored start with no registered device is never reported as display success")
    func missingDeviceReceipt() throws {
        let receipt = try PublishingDocument(json: #"{"ok":true,"pending":true,"pushToStartAttempted":0}"#)
        let answer = try SiriDashboardService.receipt(receipt, operation: .startActivity)
        #expect(answer.contains("No device has registered"))
        #expect(!answer.contains("Waiting for a device"))
        #expect(!answer.contains("displayed"))
    }

    @Test("Pending registration is reported when a start was sent to a device")
    func pendingReceipt() throws {
        let receipt = try PublishingDocument(json: #"{"ok":true,"pending":true,"pushToStartAttempted":1}"#)
        #expect(try SiriDashboardService.receipt(receipt, operation: .startActivity).contains("Waiting for a device"))
    }

    @Test("Card publication recognizes the API's card envelope, not a fictional ok field")
    func cardReceipt() throws {
        #expect(try SiriDashboardService.receipt(PublishingDocument(json: #"{"card":{"id":"new"}}"#), operation: .card) == "Dashboard card published.")
        #expect(throws: APIClientError.self) {
            try SiriDashboardService.receipt(PublishingDocument(json: #"{"ok":true}"#), operation: .card)
        }
    }

    @Test("A lunch break needs only a title and publishes activity state, not a card")
    func lunchBreakWithoutTiming() throws {
        let document = try SiriDashboardService.newActivity(title: "Lunch Break", now: Date(timeIntervalSince1970: 0))
        #expect(document.string("title") == "Lunch Break")
        #expect(document.string("kind") == "generic")
        #expect(document.string("state") == "running")
        #expect(document.string("externalActivityId")?.hasPrefix("siri-") == true)
        #expect(document.fields["template"] == nil)
        #expect(document.fields["id"] == nil)
        #expect(document.fields["endsAt"] == nil)
    }

    @Test("A known countdown stays fresh through its end rather than fifteen minutes")
    func countdownFreshness() throws {
        let document = try SiriDashboardService.newActivity(title: "Lunch Break", durationMinutes: 45, now: Date(timeIntervalSince1970: 0))
        #expect(document.string("kind") == "timer")
        #expect(document.string("endsAt") == "1970-01-01T00:45:00.000Z")
        #expect(document.string("staleAt") == document.string("endsAt"))
    }

    @Test("Contradictory, expired, and nonfinite timing is rejected")
    func invalidTiming() {
        let now = Date(timeIntervalSince1970: 0)
        for duration in [0.0, -1, 481, .infinity, .nan] {
            #expect(throws: APIClientError.self) { try SiriDashboardService.newActivity(title: "Break", durationMinutes: duration, now: now) }
        }
        #expect(throws: APIClientError.self) { try SiriDashboardService.newActivity(title: "Break", endsAt: now, now: now) }
        #expect(throws: APIClientError.self) { try SiriDashboardService.newActivity(title: "Break", durationMinutes: 10, endsAt: now.addingTimeInterval(600), now: now) }
    }

    @Test("Ordinary activity updates preserve unrelated fields and a valid countdown")
    func typedActivityUpdate() throws {
        let document = try SiriDashboardService.activityChanges(externalID: "lunch", subtitle: "Back soon", progress: 0.5, existingEndsAt: Date(timeIntervalSince1970: 2700), now: Date(timeIntervalSince1970: 0))
        #expect(document.string("externalActivityId") == "lunch")
        #expect(document.string("subtitle") == "Back soon")
        #expect(document.string("staleAt") == "1970-01-01T00:45:00.000Z")
        #expect(document.fields["endsAt"] == nil)
        #expect(document.fields["title"] == nil)
        #expect(document.fields["kind"] == nil)
    }

    @Test("Extending an activity updates its end and freshness together")
    func extendActivity() throws {
        let document = try SiriDashboardService.activityChanges(externalID: "lunch", durationMinutes: 30, now: Date(timeIntervalSince1970: 0))
        #expect(document.string("endsAt") == "1970-01-01T00:30:00.000Z")
        #expect(document.string("staleAt") == document.string("endsAt"))
        #expect(throws: APIClientError.self) { try SiriDashboardService.activityChanges(externalID: "lunch") }
    }

    @Test("Ordinary card updates preserve content and identity")
    func typedCardUpdate() throws {
        let card = DashboardCard(id: "solar", template: .summary, title: "Solar", subtitle: "House", value: "2", unit: "kW", status: .good)
        let document = try SiriDashboardService.cardChanges(card: card, value: "3")
        #expect(document.string("id") == "solar")
        #expect(document.string("value") == "3")
        #expect(document.string("unit") == "kW")
        #expect(document.string("title") == "Solar")
        #expect(document.string("subtitle") == "House")
        #expect(document.string("status") == "good")
        #expect(throws: APIClientError.self) { try SiriDashboardService.cardChanges(card: card, items: ["Not a list"]) }
    }

    @Test("A common card update cannot destroy producer-owned actions")
    func actionCardUpdate() {
        let card = DashboardCard(id: "washer", template: .action, title: "Washer", actions: [ActionDefinition(id: "ack", label: "Acknowledge")])
        #expect(throws: APIClientError.self) { try SiriDashboardService.cardChanges(card: card, value: "Done") }
    }

    @Test("Adding list titles preserves existing item identity and observations")
    func listUpdatePreservesMetadata() throws {
        let original = DashboardItem(id: "original", title: "Tickets", subtitle: "Booked", value: "2", unit: "seats", status: .good, amount: 100)
        let card = DashboardCard(id: "packing", template: .list, title: "Packing", items: [original])
        let document = try SiriDashboardService.cardChanges(card: card, items: ["Passport", "Tickets"])
        let decoded = try CardCache.jsonDecoder().decode(DashboardCard.self, from: CardCache.jsonEncoder().encode(document))
        #expect(decoded.items?.last == original)
        #expect(decoded.items?.first?.id != original.id)
        #expect(decoded.items?.first?.title == "Passport")
        #expect(throws: APIClientError.self) { try SiriDashboardService.cardChanges(card: card, items: ["Tickets", "Tickets"]) }
    }
}
