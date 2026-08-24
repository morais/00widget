import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// `zerozerowidget://` URLs are the one route shared by the widget extension,
/// the App Intents, and Spotlight. A card id is producer-chosen, so the router
/// has to survive whatever a producer named it — and the namespacing the
/// stable-id guidance asks for is exactly what puts awkward characters in one.
@Suite("Internal link routing")
struct ZeroZeroWidgetInternalLinkTests {

    @Test("A card link round-trips through the builder and the router")
    func cardLinkRoundTrips() throws {
        let url = try #require(ZeroZeroWidgetInternalLink.cardURL(id: "solar"))
        #expect(url.absoluteString == "zerozerowidget://card/solar")
        #expect(ZeroZeroWidgetInternalLink.destination(for: url) == .card(id: "solar"))
    }

    /// The namespaced ids the docs recommend contain characters a URL path
    /// treats structurally. A slash is the dangerous one: unencoded it splits
    /// the path and the router recovers a truncated id, which would open a
    /// different card rather than failing.
    @Test("Ids carrying URL-significant characters survive the round trip")
    func awkwardIdsSurvive() throws {
        for id in ["home/solar", "home solar", "solar#1", "café", "a?b", "100%"] {
            let url = try #require(ZeroZeroWidgetInternalLink.cardURL(id: id), "no URL for \(id)")
            #expect(ZeroZeroWidgetInternalLink.destination(for: url) == .card(id: id), "round trip failed for \(id)")
        }
    }

    /// The literal in `DashboardCardEntity.urlRepresentation` cannot
    /// interpolate the scheme constant — the framework only permits its own
    /// `.id` token there — so this is what stops the two drifting apart.
    @Test("The entity's URL template matches the router's scheme and host")
    func entityTemplateMatchesRouter() throws {
        let url = try #require(ZeroZeroWidgetInternalLink.cardURL(id: "x"))
        #expect(url.scheme == ZeroZeroWidgetInternalLink.scheme)
        #expect(url.absoluteString.hasPrefix("zerozerowidget://card/"))
    }

    @Test("The activities destination still routes, and reports its tab")
    func activitiesStillRoutes() throws {
        let url = try #require(URL(string: "zerozerowidget://activities"))
        #expect(ZeroZeroWidgetInternalLink.destination(for: url) == .activities)
        #expect(ZeroZeroWidgetInternalLink.Destination.activities.tab == "activities")
        #expect(ZeroZeroWidgetInternalLink.Destination.card(id: "solar").tab == "widgets")
    }

    /// A host with no id must not resolve. Returning `.card(id: "")` would push
    /// an empty detail screen rather than doing nothing.
    @Test("A card link with no id does not route")
    func emptyCardIdDoesNotRoute() throws {
        for raw in ["zerozerowidget://card", "zerozerowidget://card/"] {
            let url = try #require(URL(string: raw))
            #expect(ZeroZeroWidgetInternalLink.destination(for: url) == nil, "\(raw) should not route")
        }
        #expect(ZeroZeroWidgetInternalLink.cardURL(id: "") == nil)
    }

    @Test("Another app's scheme and an unknown host are both declined")
    func foreignURLsAreDeclined() throws {
        for raw in ["https://example.com/card/solar", "zerozerowidget://settings", "otherapp://card/solar"] {
            let url = try #require(URL(string: raw))
            #expect(ZeroZeroWidgetInternalLink.destination(for: url) == nil, "\(raw) should not route")
        }
    }

    /// The scheme arrives from the system however the sender cased it.
    @Test("Scheme and host matching is case-insensitive")
    func matchingIsCaseInsensitive() throws {
        let url = try #require(URL(string: "ZeroZeroWidget://CARD/solar"))
        #expect(ZeroZeroWidgetInternalLink.destination(for: url) == .card(id: "solar"))
    }

    /// Producer-supplied deep links go out to the browser and must stay https.
    /// The app's own scheme travels the other path entirely; if the policy ever
    /// started admitting it, an internal link could be handed to
    /// `UIApplication.open` and bounce.
    @Test("The deep link policy still refuses the app's own scheme")
    func deepLinkPolicyRejectsInternalScheme() throws {
        let url = try #require(ZeroZeroWidgetInternalLink.cardURL(id: "solar"))
        #expect(ZeroZeroWidgetDeepLinkPolicy.sanitize(url) == nil)
    }
}
