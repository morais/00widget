import CoreGraphics
import SwiftUI

/// How a `list` card spreads its rows over the canvas it is given.
///
/// A widget's row count used to be a constant chosen per family — three on a
/// medium widget, six on a large one — which is a guess about a canvas whose
/// height depends on the device, the reader's text size, and whatever else the
/// card draws under the list. The guesses were low, so a six-item card showed
/// three rows above a third of a card left blank. These are the same numbers
/// derived from the room actually measured at render time; the per-family
/// constant survives only as a readability ceiling.
public enum ListRowFill {
    /// The tallest a row may grow before extra height stops being spent on it,
    /// as a multiple of `unit`. A two-item list stretched the full height of a
    /// large widget reads as a bug rather than as a list.
    static let maxSlotUnits: CGFloat = 2.5

    /// Below this width a row's title and value cannot both grow without one
    /// of them truncating, so the type ladder does not run.
    static let minWidthForLargerType: CGFloat = 260

    /// How many rows fit in `height`, never fewer than one — a canvas too
    /// short for even one row shows one and lets it clip, which is still more
    /// than showing nothing.
    public static func capacity(height: CGFloat, unit: CGFloat) -> Int {
        max(1, Int(height / unit))
    }

    /// The height each of `rows` rows may occupy.
    public static func slot(height: CGFloat, rows: Int, unit: CGFloat) -> CGFloat {
        guard rows > 0 else { return unit }
        return min(height / CGFloat(rows), unit * maxSlotUnits)
    }

    /// Type follows the room: a list with as many rows as the canvas holds
    /// stays at `.caption`, and one with room to spare reads at the size the
    /// space deserves rather than as small print.
    public static func font(slot: CGFloat, width: CGFloat, unit: CGFloat) -> Font {
        guard width >= minWidthForLargerType else { return .caption }
        if slot >= unit * 1.9 { return .body }
        if slot >= unit * 1.35 { return .subheadline }
        return .caption
    }
}
