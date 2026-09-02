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
