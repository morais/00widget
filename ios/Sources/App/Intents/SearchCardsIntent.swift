import AppIntents
import Foundation

/// "Search 00Widget for boiler."
///
/// `ShowInAppSearchResultsIntent` and the `.system.search` schema are both iOS
/// 18, so this needs no beta toolchain. iOS 27 deprecates the protocol in
/// favour of `.system.searchInApp`, which makes that migration a schema swap
/// rather than a rewrite — building it now is not throwaway work.
///
/// The schema is what lets the system phrase the request itself, so unlike the
/// two hand-written shortcuts this one carries no phrases of its own.
///
/// `@AppIntent(schema:)` rather than `@AssistantIntent(schema:)`: the latter is
/// the name most write-ups still use and it is deprecated in the 26.5 SDK.
@AppIntent(schema: .system.search)
struct SearchCardsIntent: ShowInAppSearchResultsIntent {
    static let searchScopes: [StringSearchScope] = [.general]

    var criteria: StringSearchCriteria

    init() {
        self.criteria = StringSearchCriteria(term: "")
    }

    init(term: String) {
        self.criteria = StringSearchCriteria(term: term)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLanding.request(.search(term: criteria.term))
        return .result()
    }
}
