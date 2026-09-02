import Foundation
import SwiftUI
import Testing
@testable import ZeroZeroWidgetApp

/// A widget list used to draw a per-family constant number of rows, which is a
/// guess about a canvas whose height depends on the device, the reader's text
/// size, and whatever else the card draws under the list. The guesses were low
/// — a medium widget drew three rows into room for six — so these pin the
/// replacement: the row count comes from the room, and the constant survives
/// only as a ceiling.
@Suite("List row fill")
struct ListRowFillTests {
    private let unit: CGFloat = 19

    @Test("Row count comes from the room, not from a constant")
    func capacityFollowsHeight() {
        // A 6.3-inch medium widget's list column, and the same widget on a
        // small phone: the second holds one row fewer, and nothing in the
        // call site had to know that.
        #expect(ListRowFill.capacity(height: 129, unit: unit) == 6)
        #expect(ListRowFill.capacity(height: 107, unit: unit) == 5)
    }

    @Test("A larger text size buys fewer rows rather than an overflowing card")
    func capacityFollowsTextSize() {
        #expect(ListRowFill.capacity(height: 129, unit: unit * 2) < ListRowFill.capacity(height: 129, unit: unit))
    }

    @Test("A canvas too short for a row still shows one")
    func capacityNeverReachesZero() {
        #expect(ListRowFill.capacity(height: 4, unit: unit) == 1)
        #expect(ListRowFill.capacity(height: 0, unit: unit) == 1)
    }

    @Test("Rows spread over the canvas instead of stacking under the header")
    func slotSpreadsRows() {
        // Six rows in a large widget: each takes far more than a caption line.
        #expect(ListRowFill.slot(height: 313, rows: 6, unit: unit) > unit * 2)
        // The same six in a medium widget have no slack to spread into.
        #expect(ListRowFill.slot(height: 115, rows: 6, unit: unit) < unit * 1.1)
    }

    @Test("A short list stops growing rather than stretching across the card")
    func slotIsBounded() {
        #expect(ListRowFill.slot(height: 313, rows: 2, unit: unit) == unit * ListRowFill.maxSlotUnits)
    }

    @Test("A row count that varies by device says what it left out")
    func fitReportsHiddenRows() {
        // A large widget's list column: the ceiling of ten rows fits with
        // slack to spare, so the line saying what was left out lands in the
        // space under them and costs no data at all.
        let fit = ListRowFill.fit(
            height: 210, unit: unit, itemCount: 15, ceiling: 10, indicatorHeight: 14
        )
        #expect(fit.rows == 10)
        #expect(fit.hidden == 5)
    }

    @Test("Hiding exactly one row is not worth a row to announce")
    func oneHiddenRowStaysQuiet() {
        let fit = ListRowFill.fit(
            height: 210, unit: unit, itemCount: 11, ceiling: 10, indicatorHeight: 14
        )
        #expect(fit.rows == 10)
        #expect(fit.hidden == 0)
    }

    @Test("Nothing hidden, nothing said")
    func completeListSaysNothing() {
        let fit = ListRowFill.fit(
            height: 210, unit: unit, itemCount: 4, ceiling: 10, indicatorHeight: 14
        )
        #expect(fit.rows == 4)
        #expect(fit.hidden == 0)
    }

    @Test("Where the line does not fit under the rows it costs one")
    func theLineCanCostARow() {
        // Exactly five rows of room and no slack: the line has to come out of
        // the rows, and the count it reports grows to match.
        let fit = ListRowFill.fit(
            height: unit * 5, unit: unit, itemCount: 12, ceiling: 10, indicatorHeight: unit
        )
        #expect(fit.rows == 4)
        #expect(fit.hidden == 8)
    }

    @Test("Type follows the room")
    func fontFollowsSlot() {
        let wide: CGFloat = 340
        #expect(ListRowFill.font(slot: unit, width: wide, unit: unit) == .caption)
        #expect(ListRowFill.font(slot: unit * 1.5, width: wide, unit: unit) == .subheadline)
        #expect(ListRowFill.font(slot: unit * 2.5, width: wide, unit: unit) == .body)
    }

    @Test("A legend never outgrows the bar it is a key to")
    func legendLadderStartsLower() {
        let wide: CGFloat = 340
        #expect(ListRowFill.font(slot: unit, width: wide, unit: unit, ladder: .legend) == .caption2)
        #expect(ListRowFill.font(slot: unit * 1.5, width: wide, unit: unit, ladder: .legend) == .caption)
        #expect(ListRowFill.font(slot: unit * 2.5, width: wide, unit: unit, ladder: .legend) == .subheadline)
    }

    @Test("A narrow canvas keeps small type, which is the only size that fits")
    func narrowCanvasKeepsCaption() {
        // A small widget has the height for a larger row and not the width:
        // the extra size would be spent on ellipses.
        #expect(ListRowFill.font(slot: unit * 2.5, width: 154, unit: unit) == .caption)
        #expect(ListRowFill.font(slot: unit * 2.5, width: 154, unit: unit, ladder: .legend) == .caption2)
    }
}
