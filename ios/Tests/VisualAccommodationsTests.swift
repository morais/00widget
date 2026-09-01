import Foundation
import Testing
import SwiftUI
@testable import ZeroZeroWidgetApp

/// Increase Contrast has to raise these alphas without erasing what several
/// of them encode, and the rule is easier to get subtly wrong than to notice:
/// a role ordering that inverts, or a wash that rises until the text sitting
/// on it competes with its own background.
@Suite("Visual accommodations")
struct VisualAccommodationsTests {
    @Test("Nothing changes unless the viewer asked for more contrast")
    func defaultAppearanceIsUntouched() {
        #expect(VisualAccommodations.fillOpacity(0.35, increasedContrast: false) == 0.35)
        #expect(VisualAccommodations.washOpacity(0.05, increasedContrast: false) == 0.05)
        #expect(VisualAccommodations.ruleWidth(1, increasedContrast: false) == 1)
        #expect(ChartSeriesPalette.opacity(for: .forecast) == 0.48)
    }

    @Test("Raising a role's opacity keeps the roles in order and apart")
    func rolesStayDistinguishable() {
        // Alpha is the encoding here: flattening every role to opaque would
        // trade a contrast problem for a meaning one.
        let roles: [MetricRole?] = [.capacity, .remainder, .forecast, .baseline, .target, .actual]
        let raised = roles.map { ChartSeriesPalette.opacity(for: $0, increasedContrast: true) }

        #expect(raised == raised.sorted())
        #expect(Set(raised).count == raised.count)
        // The faintest role a chart can draw still reads.
        #expect((raised.first ?? 0) >= 0.67)
        #expect(raised.allSatisfy { $0 <= 1 })
    }

    @Test("A wash rises but stops short of competing with the text on it")
    func washesAreBounded() {
        #expect(VisualAccommodations.washOpacity(0.10, increasedContrast: true) > 0.10)
        #expect(VisualAccommodations.washOpacity(0.16, increasedContrast: true) > 0.16)
        for base in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(VisualAccommodations.washOpacity(base, increasedContrast: true) <= 0.55)
        }
    }

    @Test("A breakdown's faintest segment is raised with the rest")
    func breakdownStepsRise() {
        let item = DashboardItem(id: "a", title: "A")
        let plain = CompositionBarView.tint(for: item, index: 6, base: .blue)
        let raised = CompositionBarView.tint(for: item, index: 6, base: .blue, increasedContrast: true)

        #expect(plain != raised)
        // A status outranks the step and is a system colour, which resolves
        // its own high-contrast variant with no help from us.
        let flagged = DashboardItem(id: "b", title: "B", status: .critical)
        #expect(
            CompositionBarView.tint(for: flagged, index: 6, base: .blue)
                == CompositionBarView.tint(for: flagged, index: 6, base: .blue, increasedContrast: true)
        )
    }
}
