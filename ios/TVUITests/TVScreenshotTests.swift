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
            app.staticTexts["Solar"].waitForExistence(timeout: 30),
            "Sample widgets did not render on Apple TV."
        )
        capture(named: "screenshot-tv-widgets")
    }

    func testCaptureInsightsScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "insights"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Energy"].waitForExistence(timeout: 30),
            "Chart samples did not render on Apple TV."
        )
        XCTAssertTrue(app.staticTexts["Device fleet"].exists)
        XCTAssertTrue(app.staticTexts["Home battery"].exists)
        capture(named: "screenshot-tv-insights")
    }

    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
