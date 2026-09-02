import XCTest

/// The detail panel's row budget, against the one card that overruns it.
///
/// Nothing else can see this. The counts are a budget computed from the
/// screen's height rather than measured at render time, so a panel that asks
/// for more than 1080 lines compiles, passes every unit test, and renders — and
/// SwiftUI does not even clip it honestly. An over-tall `VStack` is *centred*
/// in the space it was given, so the overflow comes off both ends: the header
/// with the card's title and its Close button off the top, the action buttons
/// off the bottom, on a column that has nothing focusable in it and therefore
/// cannot be scrolled.
///
/// The fixture is the compound worst case — a list at its row cap, a subtitle
/// at the API's 240-character limit, a deadline, and two actions — because each
/// of those three blocks is optional and only the first was ever in the budget.
final class TVDetailBudgetTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testPanelKeepsItsHeaderAndFooterOnScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "detail-budget"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Fleet checks"].waitForExistence(timeout: 30),
            "The row-budget fixture did not render."
        )
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(
            waitForFocus(containing: "Fleet checks", in: app),
            "Expected the fixture card to take focus, found: \(focusedLabel(in: app))"
        )
        XCUIRemote.shared.press(.select)

        let close = app.buttons["Close"]
        XCTAssertTrue(
            close.waitForExistence(timeout: 10),
            "Pressing Select did not open the detail panel."
        )
        // Existence is not the assertion — a clipped element is still in the
        // accessibility tree, which is why a suite could stay green through
        // this. What is checked is that the panel's first and last chrome are
        // inside the screen.
        let screen = app.frame
        for element in [close, app.buttons["Recheck all"], app.buttons["Drain queue"]] {
            XCTAssertTrue(element.exists, "\(element) is missing from the panel entirely.")
            XCTAssertTrue(
                screen.contains(element.frame),
                "\(element.label) is outside the screen: \(element.frame) in \(screen). "
                    + "The panel overran its height and was centred."
            )
        }
    }

    private func waitForFocus(
        containing text: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if focusedLabel(in: app).contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return focusedLabel(in: app).contains(text)
    }

    private func focusedLabel(in app: XCUIApplication) -> String {
        app.descendants(matching: .any)
            .allElementsBoundByIndex
            .first(where: \.hasFocus)?
            .label ?? ""
    }
}
