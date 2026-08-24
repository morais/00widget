import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// The dashboard's search field, which "Search 00Widget for boiler" fills in.
/// A term arriving that way has been through speech recognition, so it keeps
/// neither the case nor the accents the producer wrote.
@Suite("Dashboard card search")
struct CardSearchTests {

    @Test("An empty or whitespace term is not a filter")
    func emptyTermKeepsEverything() {
        let solar = card(title: "Solar")
        #expect(CardSearch.matches(solar, term: ""))
        #expect(CardSearch.matches(solar, term: "   "))
    }

    @Test("Title matches on a substring, ignoring case and accents")
    func titleMatches() {
        #expect(CardSearch.matches(card(title: "Boiler"), term: "boil"))
        #expect(CardSearch.matches(card(title: "Café power"), term: "cafe"))
        #expect(!CardSearch.matches(card(title: "Boiler"), term: "washer"))
    }

    /// Unlike the spoken-name resolver this one has no notion of a winner, so a
    /// term matching several fields or several cards simply matches them all.
    @Test("Subtitle, value, unit and status are all searchable")
    func otherFieldsMatch() {
        var solar = card(title: "Solar")
        solar.subtitle = "Roof array"
        solar.value = "3.4"
        solar.unit = "kW"
        solar.status = .critical

        #expect(CardSearch.matches(solar, term: "roof"))
        #expect(CardSearch.matches(solar, term: "3.4"))
        #expect(CardSearch.matches(solar, term: "kw"))
        #expect(CardSearch.matches(solar, term: "critical"))
        #expect(!CardSearch.matches(solar, term: "boiler"))
    }

    /// Absent fields arrive as nil and empty strings arrive from producers that
    /// send the key with nothing in it. Neither may match a non-empty term —
    /// `range(of:)` on an empty haystack would otherwise be the deciding call.
    @Test("Absent and empty fields never match")
    func emptyFieldsDoNotMatch() {
        var bare = card(title: "Solar")
        bare.subtitle = ""
        bare.value = nil
        #expect(!CardSearch.matches(bare, term: "boiler"))
        #expect(CardSearch.matches(bare, term: "solar"))
    }

    /// A card is not hidden from search by the status word alone: "Good" is a
    /// term every healthy card matches, which is the intended behaviour and
    /// worth pinning so it is not mistaken for a bug later.
    @Test("A status word matches every card wearing that status")
    func statusIsAShareableTerm() {
        var good = card(title: "Solar"); good.status = .good
        var bad = card(title: "Boiler"); bad.status = .critical
        #expect(CardSearch.matches(good, term: "good"))
        #expect(!CardSearch.matches(bad, term: "good"))
    }

    private func card(title: String) -> DashboardCard {
        DashboardCard(id: title.lowercased(), template: .summary, title: title)
    }
}
