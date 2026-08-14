import XCTest

final class TVScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCaptureActivitiesScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "activities"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Washing machine"].waitForExistence(timeout: 30),
            "Sample Live Activity did not render on Apple TV."
        )
        capture(named: "screenshot-tv-activities")
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

    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
