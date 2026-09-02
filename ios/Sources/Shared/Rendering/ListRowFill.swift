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

    /// What a filling stack draws: how many rows, and how many items are left
    /// out once it has spent a line saying so.
    ///
    /// A dropped row is invisible — the card looks complete either way — and
    /// the count now varies with the device, the reader's text size and
    /// whatever else the card draws, so two people can see different amounts
    /// of the same card with nothing to say so. The line costs a row, which is
    /// why it appears only when it has something worth saying: hiding exactly
    /// one row is not worth giving up a row to announce, and where the line
    /// fits in the space left under the rows it costs nothing at all.
    public struct Fit: Equatable {
        public let rows: Int
        /// Zero when nothing is hidden, or when saying so is not worth a line.
        public let hidden: Int
    }

    public static func fit(
        height: CGFloat,
        unit: CGFloat,
        itemCount: Int,
        ceiling: Int,
        indicatorHeight: CGFloat
    ) -> Fit {
        let shown = min(itemCount, ceiling, capacity(height: height, unit: unit))
        guard itemCount - shown >= 2 else { return Fit(rows: shown, hidden: 0) }
        let withLine = min(
            itemCount,
            ceiling,
            capacity(height: height - indicatorHeight, unit: unit)
        )
        let rows = max(1, withLine)
        return Fit(rows: rows, hidden: itemCount - rows)
    }

    /// The height each of `rows` rows may occupy.
    public static func slot(height: CGFloat, rows: Int, unit: CGFloat) -> CGFloat {
        guard rows > 0 else { return unit }
        return min(height / CGFloat(rows), unit * maxSlotUnits)
    }

    /// The type ladder a surface climbs when it has room to spare. A legend
    /// starts a rung lower than a list: it is a key to something drawn above
    /// it, so it should not end up larger than the thing it explains.
    public enum Ladder {
        case row
        case legend

        var sizes: (base: Font, middle: Font, top: Font) {
            switch self {
            case .row: return (.caption, .subheadline, .body)
            case .legend: return (.caption2, .caption, .subheadline)
            }
        }
    }

    /// Type follows the room: a list with as many rows as the canvas holds
    /// stays at its base size, and one with room to spare reads at the size the
    /// space deserves rather than as small print.
    public static func font(
        slot: CGFloat,
        width: CGFloat,
        unit: CGFloat,
        ladder: Ladder = .row
    ) -> Font {
        let sizes = ladder.sizes
        guard width >= minWidthForLargerType else { return sizes.base }
        if slot >= unit * 1.9 { return sizes.top }
        if slot >= unit * 1.35 { return sizes.middle }
        return sizes.base
    }
}
