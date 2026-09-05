import Foundation
import SwiftUI
import Testing
import UIKit
@testable import ZeroZeroWidgetApp

/// Whether a sample card's subtitle fits the grid cell it is drawn in.
///
/// This is the iOS counterpart to `TVCardFitTests`, and it exists for the same
/// reason: a card renderer that only the widget extension can reach is one
/// nothing cheap can see. The compiler does not notice a truncated string, the
/// rest of the suite does not, and the thing that does is a 10-15 minute
/// capture run — which is where this was caught, on images that had already
/// been approved. `CardGridCell` moved into `Sources/Shared` so this test
/// could exist at all.
///
/// **The assertion is about width, not ink.** A cell's subtitle is one line
/// with no `minimumScaleFactor`, so a string that is too long does not
/// overflow the card the way a tvOS column does — it draws neatly inside the
/// box with an ellipsis on the end, which is why an ink-bounds check like the
/// television's would pass on exactly the images this is guarding. The
/// question is instead whether the string's ideal width fits the room the cell
/// gives it.
///
/// **What it does not cover.** Only the four cards the metrics capture places
/// in a grid, and only their subtitles. The scope is deliberate: a card the
/// grid does not show may carry a longer subtitle honestly, because every
/// other surface it appears on has the room for it — the Launch briefing's
/// `Release Agent · final approval` is 155pt against this cell's 146pt and
/// wraps to two lines in the small widget that actually draws it.
///
/// The header row is not covered either: it spends its width on an icon, an
/// optional status glyph and an optional attention badge as well as the title,
/// and modelling that here would duplicate the layout rather than measure it. Titles in this deck are one or two short words; if
/// that stops being true, this is the file to extend.
@MainActor
@Suite("Card grid fit")
struct CardGridFitTests {
    /// The natural width of one line at the font a cell's subtitle uses.
    private func subtitleWidth(_ text: String) -> CGFloat {
        let host = UIHostingController(
            rootView: Text(text).font(.caption2).lineLimit(1).fixedSize()
        )
        return host.sizeThatFits(in: CGSize(width: .max, height: .max)).width
    }

    /// A `systemLarge` widget on a 6.3-inch phone: the canvas the four-cell
    /// marketing capture is taken on, and the one every promotional metrics
    /// image is composed from.
    private let marketingWidgetWidth: CGFloat = 364

    @Test("No subtitle truncates in the marketing four-cell grid")
    func gridSubtitlesFitTheirCell() {
        let room = CardGridMetrics.contentWidth(
            widgetWidth: marketingWidgetWidth,
            columns: 2,
            style: .roomy
        )
        let cards = SampleDataFactory.makeCards()
        for suffix in SampleDataFactory.marketingGridCardSuffixes {
            guard let card = cards.first(where: { $0.id == SampleDataFactory.sampleId(suffix) })
            else {
                Issue.record("The marketing grid names \(suffix), which the deck no longer has.")
                continue
            }
            guard let subtitle = card.subtitle else { continue }
            let width = subtitleWidth(subtitle)
            #expect(
                width <= room,
                """
                \(card.title): "\(subtitle)" wants \(width)pt of the \(room)pt \
                a roomy cell gives it, so it draws with an ellipsis. No \
                approved App Store image may contain one — shorten the fixture \
                rather than widening the cell.
                """
            )
        }
    }

    /// The two strings that shipped truncated, kept as the calibration for the
    /// budget above: they are what proved the arithmetic matches the pixels,
    /// having been found in a real capture rather than derived.
    @Test("The budget matches the strings that were seen to truncate")
    func knownTruncationsExceedTheBudget() {
        let room = CardGridMetrics.contentWidth(
            widgetWidth: marketingWidgetWidth,
            columns: 2,
            style: .roomy
        )
        #expect(subtitleWidth("Growth Agent · up 18 this week") > room)
        #expect(subtitleWidth("Support Agent · 1 needs you") > room)
    }

    /// A smaller phone gives a cell less, and the deck does not fit it. That is
    /// deliberate rather than unnoticed: the App Store sets are captured at
    /// 6.3 inches, 6.5 inches and iPad, all of which are at least as wide as
    /// the budget above, and shortening every subtitle to a 4.7-inch screen
    /// would cost the wording the plan chose for the images that ship. The
    /// figure is recorded so a future change knows what it is trading.
    @Test("The smallest phone's budget is known and smaller")
    func smallestPhoneBudgetIsRecorded() {
        let smallest = CardGridMetrics.contentWidth(
            widgetWidth: 321,
            columns: 2,
            style: .roomy
        )
        let marketing = CardGridMetrics.contentWidth(
            widgetWidth: marketingWidgetWidth,
            columns: 2,
            style: .roomy
        )
        #expect(smallest < marketing)
        #expect(smallest == 124.5)
    }
}
