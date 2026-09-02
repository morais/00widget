import XCTest

/// Guards the visual hierarchy reported from a real television: the second
/// line is the reading and must be physically taller than the context below it.
final class TVTypographyHierarchyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testChartValueIsLargerThanSubtitle() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "typography"]
        app.launch()

        let value = app.staticTexts["57–73%"]
        let subtitle = app.staticTexts["Min–max RH · Jul 29–Aug 29 · target 40–60%"]
        XCTAssertTrue(value.waitForExistence(timeout: 30))
        XCTAssertTrue(subtitle.exists)
        XCTAssertGreaterThan(
            value.frame.height,
            subtitle.frame.height,
            "The chart's primary value must render larger than its subtitle."
        )

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "tv-chart-typography-hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
