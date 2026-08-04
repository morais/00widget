import XCTest

/// Captures the marketing screenshots published on 00widget.com.
///
/// This exists as a UI test because the simulator offers no other way in: the
/// app opens on Settings until an API key is in the Keychain (which cannot be
/// seeded from outside the device), `onOpenURL` forwards external links rather
/// than routing tabs, and there is no tap tooling — `simctl` has no tap verb and
/// the Simulator exposes no accessibility windows. XCUITest can tap, so it can
/// drive the app into each state the website shows.
///
/// Run via `ios/scripts/capture-screenshots.sh`, which sets a stable status bar,
/// runs this test, and extracts the attachments out of the .xcresult bundle.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCaptureMarketingScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        let widgetsTab = app.tabBars.buttons["Widgets"]
        XCTAssertTrue(
            widgetsTab.waitForExistence(timeout: 30),
            "Tab bar never appeared — the app may have failed to launch."
        )
        widgetsTab.tap()

        // Populate the dashboard through the app's own empty-state button rather
        // than pre-seeding the App Group cache, so the screenshot shows a state a
        // real user can actually reach. Already-populated runs skip this.
        let generate = app.buttons["Generate sample widgets"]
        if generate.waitForExistence(timeout: 5) {
            generate.tap()
        }

        XCTAssertTrue(
            app.staticTexts["Solar"].waitForExistence(timeout: 15),
            "Sample cards did not render on the Widgets tab."
        )
        capture(named: "screenshot-widgets")

        let activitiesTab = app.tabBars.buttons["Activities"]
        if activitiesTab.waitForExistence(timeout: 5) {
            activitiesTab.tap()

            // Start a local sample so the tab shows a running activity rather
            // than its empty state. This is a real ActivityKit activity —
            // `Activity.request` works on the simulator; only *push*-started
            // activities need APNs, which the simulator cannot receive.
            let generateActivity = app.buttons["Generate sample activity"]
            if generateActivity.waitForExistence(timeout: 5) {
                generateActivity.tap()
            }

            XCTAssertTrue(
                app.staticTexts["Washing machine"].waitForExistence(timeout: 15),
                "Sample Live Activity did not start."
            )
            capture(named: "screenshot-activities")
        }
    }

    /// Captures the whole screen, not `app.screenshot()`, so the status bar is
    /// included — the published shots show it.
    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
