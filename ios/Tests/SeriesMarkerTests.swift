import CoreGraphics
import Foundation
import Testing
import SwiftUI
@testable import ZeroZeroWidgetApp

/// A texture that draws nothing, or a legend glyph that does not match the
/// region it names, looks like a perfectly ordinary chart. Neither the build
/// nor a screenshot of the default appearance can see either, because both
/// only appear once Differentiate Without Color is on.
@Suite("Series markers")
struct SeriesMarkerTests {
    @Test("Markers cycle so a breakdown longer than the palette still alternates")
    func markersCycle() {
        #expect(SeriesMarker.at(0) == .circle)
        #expect(SeriesMarker.at(3) == .diamond)
        #expect(SeriesMarker.at(4) == .circle)
        // Adjacency is what a bar needs; nothing here may ever hand two
        // neighbours the same marker.
        for index in 0..<12 {
            #expect(SeriesMarker.at(index) != SeriesMarker.at(index + 1))
        }
    }

    @Test("The first series is untextured, and every other one is not")
    func firstSeriesStaysPlain() {
        // One series has nothing to be told apart from, so an ordinary chart
        // looks the same whether or not the setting is on.
        #expect(SeriesMarker.circle.hatch == nil)
        for marker in SeriesMarker.allCases where marker != .circle {
            #expect(marker.hatch != nil)
        }
        #expect(Set(SeriesMarker.allCases.map(\.symbolName)).count == SeriesMarker.allCases.count)
    }

    @Test("A diagonal hatch reaches the corners of the region it fills")
    func diagonalCoversCorners() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 12)
        let path = SeriesHatchShape(hatch: .forwardDiagonal, spacing: 5).path(in: rect)

        #expect(!path.isEmpty)
        // A 45° rule leaves through the side it entered by, displaced by the
        // height: sweeping only across the width leaves both far corners bare.
        #expect(path.boundingRect.minX <= rect.minX - rect.height + 5)
        #expect(path.boundingRect.maxX >= rect.maxX)
    }

    @Test("A hatch of no width draws nothing rather than looping")
    func degenerateRectIsEmpty() {
        for hatch in [SeriesHatch.forwardDiagonal, .backDiagonal, .vertical] {
            #expect(SeriesHatchShape(hatch: hatch).path(in: .zero).isEmpty)
        }
    }
}
