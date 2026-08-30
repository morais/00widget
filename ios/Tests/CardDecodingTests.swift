import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// `DashboardCard`'s decoder deliberately tolerates values this build
/// predates, because the server is versioned independently of the app and one
/// unrecognised card must not take a whole cached list down with it. Those
/// fallbacks are load-bearing and invisible: a card that decodes wrongly still
/// renders, so nothing reports the failure.
@Suite("Dashboard card decoding")
struct CardDecodingTests {

    @Test("A template this build predates falls back to summary instead of throwing")
    func unknownTemplateFallsBack() throws {
        let card = try decode(#"{"id":"c1","template":"hologram","title":"Solar"}"#)
        #expect(card.template == .summary)
    }

    @Test("An unrecognised status falls back to unknown")
    func unknownStatusFallsBack() throws {
        let card = try decode(#"{"id":"c1","template":"summary","title":"Solar","status":"melting"}"#)
        #expect(card.status == .unknown)
    }

    @Test("A whole list survives one card from a newer server")
    func oneUnknownCardDoesNotTakeTheListDown() throws {
        let json = """
        [{"id":"c1","template":"hologram","title":"Solar"},
         {"id":"c2","template":"progress","title":"Washer"}]
        """
        let cards = try JSONDecoder().decode([DashboardCard].self, from: Data(json.utf8))
        #expect(cards.count == 2)
        #expect(cards[0].template == .summary)
        #expect(cards[1].template == .progress)
    }

    @Test("A briefing keeps its ordered plain-text sections")
    func briefingDecodes() throws {
        let card = try decode(
            #"{"id":"c1","template":"briefing","title":"Release","value":"2 blockers","briefing":{"sections":[{"id":"impact","label":"Impact","text":"Refunds are delayed."}]}}"#
        )
        #expect(card.template == .briefing)
        #expect(card.briefing?.sections.first?.label == "Impact")
        #expect(card.briefing?.sections.first?.text == "Refunds are delayed.")
    }

    /// Deep links arrive from producers, and a card is rendered by the widget
    /// extension, so the sanitising has to happen where the value enters the
    /// process rather than where it is tapped.
    @Test("A non-https deep link is dropped at decode")
    func customSchemeDeepLinkIsDropped() throws {
        let card = try decode(
            #"{"id":"c1","template":"summary","title":"Solar","deepLink":"zerozerowidget://open"}"#
        )
        #expect(card.deepLink == nil)
    }

    @Test("An https deep link survives decode")
    func httpsDeepLinkSurvives() throws {
        let card = try decode(
            #"{"id":"c1","template":"summary","title":"Solar","deepLink":"https://example.com/a"}"#
        )
        #expect(card.deepLink?.absoluteString == "https://example.com/a")
    }

    /// The id prefix is the only signal the app and the widget extension share
    /// for telling published cards from samples and from another tenant's
    /// shared cards. The delete button and the guest read-only rendering both
    /// key off these.
    @Test("Sample and guest cards are recognised by id prefix")
    func prefixesIdentifyOrigin() {
        let sample = card(id: ZeroZeroWidgetConstants.sampleCardIdPrefix + "solar")
        #expect(sample.isSample)
        #expect(!sample.isFromGuestLink)

        let guest = card(id: ZeroZeroWidgetConstants.guestCardIdPrefix + "solar")
        #expect(guest.isFromGuestLink)
        #expect(!guest.isSample)

        let published = card(id: "solar")
        #expect(!published.isSample)
        #expect(!published.isFromGuestLink)
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> DashboardCard {
        try JSONDecoder().decode(DashboardCard.self, from: Data(json.utf8))
    }

    private func card(id: String) -> DashboardCard {
        DashboardCard(id: id, template: .summary, title: "Solar")
    }
}

/// Every producer-supplied URL passes through this before it is stored on a
/// card or a Live Activity, so it is the single place a hostile deep link can
/// be stopped.
@Suite("Deep link policy")
struct DeepLinkPolicyTests {

    @Test("Only https URLs carrying a host survive")
    func onlyHTTPSWithHostSurvives() {
        #expect(sanitize("https://example.com/a")?.absoluteString == "https://example.com/a")
        #expect(sanitize("HTTPS://example.com/a") != nil, "scheme comparison is case-insensitive")

        #expect(sanitize("http://example.com/a") == nil)
        #expect(sanitize("zerozerowidget://open") == nil)
        #expect(sanitize("javascript:alert(1)") == nil)
        #expect(sanitize("file:///etc/passwd") == nil)
        #expect(sanitize("https:///nohost") == nil)
    }

    @Test("A nil URL stays nil")
    func nilStaysNil() {
        #expect(ZeroZeroWidgetDeepLinkPolicy.sanitize(nil) == nil)
    }

    private func sanitize(_ string: String) -> URL? {
        ZeroZeroWidgetDeepLinkPolicy.sanitize(URL(string: string))
    }
}
