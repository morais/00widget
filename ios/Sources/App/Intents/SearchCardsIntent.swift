import AppIntents
import Foundation

/// "Search 00Widget for boiler."
///
/// `ShowInAppSearchResultsIntent` itself carries no deprecation: verified
/// 2026-09-07 against the iOS 27 SDK (`AppIntents.swiftmodule`, 301.0.51.1.102),
/// where the protocol is still current and what is deprecated is the
/// `.system.search` *schema* (`@available(anyAppleOS, deprecated: 27.0,
/// message: "Use .system.searchInApp instead")`, mapping to
/// `ShowInAppSearchResultsIntent`, with `.system.searchInApp` mapping to
/// `SystemSearchInAppIntent` and gated `@available(anyAppleOS 27.0, *)`).
/// The earlier comment here said the protocol was deprecated, which was
/// imprecise in a load-bearing way.
///
/// This stays on `.system.search` for now. The replacement schema is 27-only
/// at runtime while the app still deploys back to iOS 26, so swapping the
/// schema today would make the intent unrecognised on 26. Revisit when the
/// deployment target moves to 27: the migration is a schema swap on this same
/// protocol conformance, not a rewrite.
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
