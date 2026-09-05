import Foundation

/// A step counter a producer wrote into `value` instead of into `progress` —
/// "1/4", "Capture 1/4", "3 of 8".
///
/// Narrow on purpose: both sides whole numbers, each one adjacent to the
/// separator, the second non-zero and no smaller than the first. Anything
/// looser starts reading version strings and aspect ratios as completion.
/// Sending `progress` remains the supported path; this exists because the
/// Dynamic Island's minimal circle has no room for the string itself, so
/// without it a producer who counts in prose gets a glyph and nothing else.
/// A value that is genuinely a date — "3/4" — is read as a fraction here, and
/// the only consequence is a ring drawn at three quarters.
public enum LiveActivityValueFraction {
    public static func value(in text: String) -> Double? {
        let normalized = text.replacingOccurrences(of: " of ", with: "/", options: [.caseInsensitive])
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let done = trailingInteger(in: parts[0]),
              let total = leadingInteger(in: parts[1]),
              total > 0,
              done <= total
        else { return nil }
        return Double(done) / Double(total)
    }

    /// The digits immediately before the separator, and only if what precedes
    /// them is nothing or a space — so "Capture 1" counts and "v1.2" does not.
    private static func trailingInteger(in text: Substring) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.reversed().prefix(while: \.isWholeNumber).reversed()
        guard !digits.isEmpty, digits.count <= 6 else { return nil }
        let head = trimmed.dropLast(digits.count)
        guard head.isEmpty || head.hasSuffix(" ") else { return nil }
        return Int(String(digits))
    }

    private static func leadingInteger(in text: Substring) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: \.isWholeNumber)
        guard !digits.isEmpty, digits.count <= 6 else { return nil }
        let tail = trimmed.dropFirst(digits.count)
        guard tail.isEmpty || tail.hasPrefix(" ") else { return nil }
        return Int(String(digits))
    }
}

#if canImport(ActivityKit)
public extension ZeroZeroWidgetActivityAttributes.ContentState {
    var activeItems: [LiveActivityItem] {
        (items ?? []).filter(\.isActive)
    }

    /// Rows that explain the activity on surfaces with room for its parts.
    ///
    /// Active work stays first so the current decision is never displaced by
    /// history. Finished rows follow in producer order as recent proof, while
    /// offline rows remain absent. This is deliberately separate from
    /// `activeItems`: counts, badges, progress derivation, and the overall
    /// accessibility summary must continue to describe unfinished work only.
    var presentationItems: [LiveActivityItem] {
        Self.presentationItems(from: items)
    }

    var hasExplicitValue: Bool {
        !(value ?? "").isEmpty
    }

    // The active-item count is a *derived* stand-in for a value the producer
    // did not send. A composite activity that publishes its own `value` means
    // it, so the count must never overwrite it with "2 active".
    var showsItemCount: Bool {
        !activeItems.isEmpty && !hasExplicitValue
    }

    /// The fraction the Dynamic Island's minimal ring draws, or `nil` when
    /// nothing about this activity honestly reads as completion.
    ///
    /// A ring stuck at zero is worse than no ring — it says "nothing has
    /// happened" about an activity that may be halfway through — so each
    /// derivation has to be earned. An explicit `progress` wins; then a set of
    /// items far enough along to have finished one, or one where every item
    /// carries its own progress; then a counter the producer wrote into
    /// `value`. This is the minimal circle's ladder only: the Lock Screen and
    /// the compact regions have room for the real thing and read `progress`
    /// alone.
    var minimalProgress: Double? {
        if let progress { return max(0, min(progress, 1)) }
        if let derived = itemProgress { return derived }
        if let value, let fraction = LiveActivityValueFraction.value(in: value) { return fraction }
        return nil
    }

    /// A `value` short enough to read in a circle about 24pt across. Three
    /// glyphs is the budget — "1/4", "78%", "20°" fit; "Capture 1/4" does not,
    /// and clipping it to "Cap" would read as a word rather than as truncation.
    var minimalValueToken: String? {
        Self.token(in: value, budget: 3)
    }

    /// A string short enough for the Dynamic Island's *compact* trailing
    /// region, which is wider than the minimal circle and still small.
    ///
    /// The region neither wraps nor scales what it is given: it clips, and
    /// from the leading edge, so "Announcement 4/5" arrives as
    /// "ouncement 4/5" — which reads as a word rather than as truncation.
    /// `fixedSize()` is needed as well and is not sufficient on its own: it
    /// makes the region negotiate a width instead of accepting a clipped one,
    /// which is what lets even "4/5" render at all, but with a long string it
    /// grows the island across most of the screen *and* clips it anyway. So
    /// the budget is what keeps it honest, and six glyphs is it — measured
    /// against the countdown this replaced, which sat comfortably at "~8 min".
    ///
    /// Nothing is shown rather than something clipped. The leading glyph still
    /// says which activity this is, and the Lock Screen, the expanded island
    /// and every widget surface have room for the value in full.
    var compactValueToken: String? {
        Self.token(in: value, budget: 6)
    }

    /// The same budget applied to any other string a compact region might
    /// fall back to, so a new branch cannot reintroduce the clipping.
    static func compactToken(_ raw: String?) -> String? {
        token(in: raw, budget: 6)
    }

    private static func token(in raw: String?, budget: Int) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= budget else { return nil }
        return trimmed
    }

    private var itemProgress: Double? {
        guard let items, !items.isEmpty else { return nil }
        let finished = items.filter { !$0.isActive }.count
        if finished > 0 { return Double(finished) / Double(items.count) }
        let progresses = items.compactMap(\.progress)
        guard progresses.count == items.count else { return nil }
        let mean = progresses.reduce(0, +) / Double(progresses.count)
        return max(0, min(mean, 1))
    }

    private static func presentationItems(from items: [LiveActivityItem]?) -> [LiveActivityItem] {
        let rows = items ?? []
        return rows.filter(\.isActive) + rows.filter { $0.status == .finished }
    }
}
#endif

public extension LiveActivitySession {
    var activeItems: [LiveActivityItem] {
        (items ?? []).filter(\.isActive)
    }

    /// The full row collection used by scrollable and otherwise unconstrained
    /// activity presentations. See the matching ContentState property above.
    var presentationItems: [LiveActivityItem] {
        let rows = items ?? []
        return rows.filter(\.isActive) + rows.filter { $0.status == .finished }
    }

    /// Television cards and detail panels cannot scroll their activity rows.
    /// Preserve every genuinely active row, then fill a sparse presentation
    /// with only enough finished proof to reach the requested row count.
    func budgetedPresentationItems(fillingTo minimumCount: Int) -> [LiveActivityItem] {
        let active = activeItems
        let finishedLimit = max(0, minimumCount - active.count)
        let finished = (items ?? []).filter { $0.status == .finished }.prefix(finishedLimit)
        return active + Array(finished)
    }
}
