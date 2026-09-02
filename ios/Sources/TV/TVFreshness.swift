import SwiftUI

/// `FreshnessLine` with the television's reading affordances on it.
///
/// The rule this exists to hold is in the shared view: the Apple TV dashboard
/// and the Lock Screen Live Activity go quiet the same way, and must say so
/// with the same words. Only the type scaling is tvOS's own.
struct TVFreshness: View {
    let updatedAt: Date
    let isStale: () -> Bool
    let font: Font

    var body: some View {
        FreshnessLine(updatedAt: updatedAt, isStale: isStale, font: font)
            .tvReadableText(largeTextLineLimit: 2)
    }
}
