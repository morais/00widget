import XCTest

/// Exercises the tvOS 27 layout branches on an Xcode 26 simulator by using the
/// screenshot-only Dynamic Type override in `ZeroZeroWidgetTVApp`.
final class TVLargeTextTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The half of the range that had no coverage at all.
    ///
    /// `.xxxLarge` is not an accessibility size, so the grid keeps its three
    /// columns and a cell keeps a *fixed* height — which is exactly the shape
    /// of the overflow this app has hit before: a `VStack` given less height
    /// than it needs is centred and drawn straight through its padding, and
    /// neither the build nor a green suite can see it. What a test can see is
    /// that the row is still a row, and that focus still reaches it.
    func testEnlargedTextKeepsThreeColumnsAndStaysReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--screenshot-section", "insights",
            "--large-text-preview", "xxxLarge",
        ]
        app.launch()

        let energy = app.staticTexts["Energy"]
        let deploys = app.staticTexts["Deploys"]
        let fleet = app.staticTexts["Device fleet"]
        XCTAssertTrue(energy.waitForExistence(timeout: 30))
        XCTAssertTrue(deploys.exists)
        XCTAssertTrue(fleet.exists)

        // One row, unlike the accessibility case below, which drops to two
        // columns and pushes the third card down.
        XCTAssertLessThan(fleet.frame.minY, deploys.frame.maxY)

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(
            waitForFocus(containing: "Energy", in: app)
                || waitForFocus(containing: "Deploys", in: app)
                || waitForFocus(containing: "Device fleet", in: app),
            "Enlarged text left the widget row unreachable, found: \(focusedLabel(in: app))"
        )

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "tv-enlarged-text-dashboard"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDashboardAndDetailUseLargeTextLayout() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--screenshot-section", "insights",
            "--large-text-preview",
        ]
        app.launch()

        let energy = app.staticTexts["Energy"]
        let deploys = app.staticTexts["Deploys"]
        let fleet = app.staticTexts["Device fleet"]
        XCTAssertTrue(energy.waitForExistence(timeout: 30))
        XCTAssertTrue(deploys.exists)
        XCTAssertTrue(fleet.exists)

        // Standard tvOS shows these three cards in one row. Accessibility
        // sizes reduce the dashboard to two columns, putting the third card on
        // a new row with enough width for enlarged labels.
        XCTAssertGreaterThan(fleet.frame.minY, deploys.frame.maxY)

        XCUIRemote.shared.press(.down)
        for _ in 0..<3 where !focusedLabel(in: app).contains("Energy") {
            XCUIRemote.shared.press(.left)
        }
        XCTAssertTrue(
            waitForFocus(containing: "Energy", in: app),
            "Expected Energy to take focus, found: \(focusedLabel(in: app))"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["chart-inspector"].waitForExistence(timeout: 10))
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
