import Foundation
import Testing
import AppIntents
@testable import ZeroZeroWidgetApp

/// `DashboardCardEntityQuery` used to be a bare `EntityQuery`: rehydrate by id,
/// list suggestions, nothing else. It could not answer "which cards need
/// attention" — the question the widget's own status filter has described since
/// it was written, from inside the extension where the app could not see it.
///
/// These cover the predicate semantics through the pure `filter`, so they hold
/// without the AppIntents runtime driving them.
@Suite("Card property query")
struct CardQueryTests {

    typealias Query = DashboardCardEntityQuery
    typealias Sort = DashboardCardEntityQuery.CardSortOrder

    // MARK: - The grouping predicates

    /// `paused` belongs to two groups at once — a paused washer is stuck and
    /// running — which is why these are overlapping predicates rather than one
    /// grouping property a card could hold a single value for.
    @Test("Paused counts as both needing attention and active")
    func pausedIsInTwoGroups() {
        #expect(DashboardStatus.paused.needsAttention)
        #expect(DashboardStatus.paused.isActive)
        #expect(!DashboardStatus.paused.isHealthy)
    }

    /// `unknown` is the decoder's fallback for a status this build predates, so
    /// a card wearing it is one the app cannot vouch for. Sorting it with the
    /// healthy cards would hide exactly the card worth looking at.
    @Test("An unrecognised status needs attention rather than passing as healthy")
    func unknownNeedsAttention() {
        #expect(DashboardStatus.unknown.needsAttention)
        #expect(!DashboardStatus.unknown.isHealthy)
    }

    @Test("Every status falls into at least one group")
    func everyStatusIsCovered() {
        for status in DashboardStatus.allCases {
            #expect(status.needsAttention || status.isActive || status.isHealthy, "\(status) is in no group")
        }
    }

    /// `WidgetStatusFilter` itself cannot be reached from here — it lives in
    /// the widget extension, which is exactly the problem this change was
    /// about. It now delegates to these three predicates rather than restating
    /// them, so agreement holds by construction and this is where the meaning
    /// is pinned.
    @Test("The groups partition into the meanings the widget filter offers")
    func groupsMatchTheWidgetVocabulary() {
        #expect(DashboardStatus.critical.needsAttention)
        #expect(DashboardStatus.warning.needsAttention)
        #expect(DashboardStatus.offline.needsAttention)
        #expect(DashboardStatus.running.isActive)
        #expect(DashboardStatus.good.isHealthy)
        #expect(DashboardStatus.finished.isHealthy)
        #expect(!DashboardStatus.good.needsAttention)
        #expect(!DashboardStatus.running.needsAttention)
    }

    // MARK: - Filtering

    @Test("Needs-attention filtering returns exactly the cards in that group")
    func needsAttentionFilter() {
        let cards = [
            card("solar", .good),
            card("boiler", .critical),
            card("washer", .paused),
            card("deploys", .running)
        ]
        let matched = Query.filter(cards, matching: [predicate { $0.status.needsAttention }], mode: .and, sortedBy: [], limit: nil)
        #expect(matched.map(\.id) == ["boiler", "washer"])
    }

    /// The mode is the caller's, and the two are not interchangeable — an `.or`
    /// over the same two predicates is a much larger answer.
    @Test("and requires every predicate, or requires any")
    func modesDiffer() {
        let cards = [card("solar", .good), card("boiler", .critical), card("washer", .paused)]
        let attention = predicate { $0.status.needsAttention }
        let active = predicate { $0.status.isActive }

        #expect(Query.filter(cards, matching: [attention, active], mode: .and, sortedBy: [], limit: nil).map(\.id) == ["washer"])
        #expect(Query.filter(cards, matching: [attention, active], mode: .or, sortedBy: [], limit: nil).map(\.id) == ["boiler", "washer"])
    }

    /// A Find action with no filters is a request for everything. Under `.or`
    /// an empty predicate list is vacuously false, which would answer it with
    /// nothing — a wrong answer to a question nobody asked.
    @Test("No comparators means everything, under either mode")
    func emptyComparatorsMatchEverything() {
        let cards = [card("solar", .good), card("boiler", .critical)]
        #expect(Query.filter(cards, matching: [], mode: .and, sortedBy: [], limit: nil).count == 2)
        #expect(Query.filter(cards, matching: [], mode: .or, sortedBy: [], limit: nil).count == 2)
    }

    @Test("A limit truncates without disturbing the order")
    func limitTruncates() {
        let cards = [card("a", .good), card("b", .good), card("c", .good)]
        #expect(Query.filter(cards, matching: [], mode: .and, sortedBy: [], limit: 2).map(\.id) == ["a", "b"])
        #expect(Query.filter(cards, matching: [], mode: .and, sortedBy: [], limit: 9).count == 3)
    }

    // MARK: - Sorting

    @Test("Sorting by title runs both ways")
    func titleSort() {
        let cards = [card("b", .good, title: "Boiler"), card("a", .good, title: "Aircon")]
        let ascending = Query.filter(cards, matching: [], mode: .and, sortedBy: [Sort(field: .title, ascending: true)], limit: nil)
        let descending = Query.filter(cards, matching: [], mode: .and, sortedBy: [Sort(field: .title, ascending: false)], limit: nil)
        #expect(ascending.map(\.title) == ["Aircon", "Boiler"])
        #expect(descending.map(\.title) == ["Boiler", "Aircon"])
    }

    @Test("Sorting by last-updated orders by the card's own timestamp")
    func updatedAtSort() {
        let now = Date()
        var old = card("old", .good); old.updatedAt = now.addingTimeInterval(-3600)
        var recent = card("recent", .good); recent.updatedAt = now

        let sorted = Query.filter([old, recent], matching: [], mode: .and, sortedBy: [Sort(field: .updatedAt, ascending: false)], limit: nil)
        #expect(sorted.map(\.id) == ["recent", "old"])
    }

    /// Chained sorts only mean anything if the second one preserves the first
    /// where it ties, and Swift's sort is not stable — so equal elements have
    /// to be tie-broken explicitly.
    @Test("A second sort preserves the first where values tie")
    func chainedSortIsStable() {
        let now = Date()
        var first = card("first", .good, title: "Same"); first.updatedAt = now
        var second = card("second", .good, title: "Same"); second.updatedAt = now.addingTimeInterval(-60)
        var third = card("third", .critical, title: "Other"); third.updatedAt = now

        let sorted = Query.filter(
            [first, second, third],
            matching: [],
            mode: .and,
            sortedBy: [
                Sort(field: .title, ascending: true),
                Sort(field: .updatedAt, ascending: false)
            ],
            limit: nil
        )
        // Title first: "Other" before "Same"; then the two "Same" cards by recency.
        #expect(sorted.map(\.id) == ["third", "first", "second"])
    }

    /// Ties within a single sort keep the order they arrived in, which is the
    /// server's priority order — a better answer than an arbitrary one.
    @Test("Equal values keep the order they came in")
    func tiesAreStable() {
        let now = Date()
        var a = card("a", .good, title: "Same"); a.updatedAt = now
        var b = card("b", .good, title: "Same"); b.updatedAt = now
        let sorted = Query.filter([a, b], matching: [], mode: .and, sortedBy: [Sort(field: .title, ascending: true)], limit: nil)
        #expect(sorted.map(\.id) == ["a", "b"])
    }

    // MARK: - Helpers

    private func predicate(_ matches: @escaping (DashboardCard) -> Bool) -> DashboardCardEntityQuery.CardPredicate {
        DashboardCardEntityQuery.CardPredicate(matches: matches)
    }

    private func card(_ id: String, _ status: DashboardStatus, title: String = "Card") -> DashboardCard {
        DashboardCard(id: id, template: .summary, title: title, status: status)
    }
}
