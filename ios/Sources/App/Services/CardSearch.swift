import Foundation

/// Filtering the dashboard by a search term.
///
/// Deliberately not `DashboardCardEntityQuery.matches`, which resolves a spoken
/// name to *one* entity and so lets an exact title win outright. A list filter
/// wants the opposite: every card a person might have meant, in the order the
/// server ranked them. The two look similar and answer different questions.
enum CardSearch {
    /// Everything a person can see on a card, because that is what they will
    /// type. Case- and accent-insensitive: the term may have arrived from
    /// speech via "Search 00Widget for boiler", where neither survives.
    static func matches(_ card: DashboardCard, term: String) -> Bool {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty term is not a filter. Returning false would blank the
        // dashboard the moment someone tapped the search field.
        guard !needle.isEmpty else { return true }

        let haystacks = [
            card.title,
            card.subtitle,
            card.value,
            card.unit,
            card.status.label
        ]
        return haystacks.contains { field in
            guard let field, !field.isEmpty else { return false }
            return field.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
