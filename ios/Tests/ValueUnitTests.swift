import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// The app's item rows were the one surface that concatenated a value and its
/// unit raw, so a sample card read "1204jobs" on the phone while the guest page
/// showing the same card read "1204 jobs".
@Suite("Value and unit")
struct ValueUnitTests {
    @Test("A unit that is a word is a word")
    func wordUnitsAreSpaced() {
        #expect(ValueUnit.joined("1204", "jobs") == "1204 jobs")
        #expect(ValueUnit.joined("142", "ms") == "142 ms")
        #expect(ValueUnit.joined("3.2", "kW") == "3.2 kW")
    }

    @Test("A symbol that binds to its number stays bound")
    func boundSymbolsAreTight() {
        #expect(ValueUnit.joined("62", "%") == "62%")
        #expect(ValueUnit.joined("21.5", "°C") == "21.5°C")
    }

    @Test("Nothing to join")
    func missingParts() {
        #expect(ValueUnit.joined(nil, "jobs") == nil)
        #expect(ValueUnit.joined("8", nil) == "8")
        #expect(ValueUnit.joined("8", "") == "8")
    }

    @Test("Items and cards read the same way")
    func modelsAgree() {
        let item = DashboardItem(id: "q", title: "Queue", value: "1204", unit: "jobs")
        #expect(item.displayValue == "1204 jobs")
        let card = DashboardCard(id: "c", template: .summary, title: "Solar", value: "3.2", unit: "kW")
        #expect(card.displayValue == "3.2 kW")
        #expect(DashboardCard(id: "d", template: .summary, title: "No value").displayValue == nil)
    }
}
