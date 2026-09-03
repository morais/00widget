import XCTest

final class TVScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCaptureWidgetsScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "widgets"]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Launch"].waitForExistence(timeout: 30),
            "Sample widgets did not render on Apple TV."
        )
        capture(named: "screenshot-tv-widgets")
    }

    func testCaptureInsightsScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "insights"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Trials"].waitForExistence(timeout: 30),
            "Chart samples did not render on Apple TV."
        )
        XCTAssertTrue(app.staticTexts["Support"].exists)
        XCTAssertTrue(app.staticTexts["App launch"].exists)
        capture(named: "screenshot-tv-insights")
    }

    /// The detail panel, which is the surface the dashboard grid is a summary
    /// of. Trials is the chart sample, so the panel it opens is the one that
    /// most obviously shows what the extra room buys: a plot with a shape,
    /// rather than the 46-point trace a grid cell has space for.
    ///
    /// The insights section is used rather than the widgets one because it puts
    /// Trials first in the grid, so the walk to it is a single press and cannot
    /// drift when the sample set is re-composed.
    func testCaptureCardDetailScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "insights"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Trials"].waitForExistence(timeout: 30),
            "Chart samples did not render on Apple TV."
        )
        // Down leaves the Live Activity for the widget row, but it lands in the
        // middle column rather than the first: the activity card spans the
        // whole width, so tvOS picks the card nearest the horizontal position
        // focus was already at. Walking left is what reaches the first column,
        // and pressing left at the edge is a no-op, so the loop is safe to
        // overshoot.
        XCUIRemote.shared.press(.down)
        for _ in 0..<3 where !focusedLabel(in: app).contains("Trials") {
            XCUIRemote.shared.press(.left)
            _ = waitForFocus(containing: "Trials", in: app, timeout: 1)
        }
        XCTAssertTrue(
            waitForFocus(containing: "Trials", in: app),
            "Expected the Trials card to take focus, found: \(focusedLabel(in: app))"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["Close"].waitForExistence(timeout: 10),
            "Pressing Select on the Trials card did not open its detail panel."
        )
        // The panel animates in, and a capture taken mid-transition shows the
        // dashboard bleeding through a half-opaque cover. The interactive
        // chart is now the panel's initial focus target, so waiting for Close
        // is both stale and misses the focus treatment this image should show.
        let inspector = app.otherElements["chart-inspector"]
        XCTAssertTrue(
            inspector.waitForExistence(timeout: 10) && waitForFocus(on: inspector),
            "The detail panel never settled with focus on its chart inspector."
        )
        capture(named: "screenshot-tv-card-detail")
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

    private func waitForFocus(on element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.hasFocus { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return element.hasFocus
    }

    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
