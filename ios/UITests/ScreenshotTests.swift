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

        hideSampleIndicators(in: app)

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

            // Backgrounding surfaces the activity in the Dynamic Island, which
            // is the only way to see it — it does not render while the app is
            // foremost.
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 3)
            capture(named: "screenshot-home-dynamic-island")

            // Long-press the island to reach the expanded presentation, which
            // is what the published screenshot shows: title, subtitle, state,
            // and the progress bar rather than a bare percentage.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            springboard
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.022))
                .press(forDuration: 1.2)
            Thread.sleep(forTimeInterval: 2)
            capture(named: "screenshot-home-expanded")
        }
    }

    /// Turns off the "SAMPLE" badges and the "these are samples" notices via
    /// Settings → Developer, so the shots show the product rather than the
    /// labelling. The Developer section only exists because
    /// `capture-screenshots.sh` builds with `ZW_DEBUG_TOOLS=YES`; a shipping
    /// build has no such screen and no way to reach this flag.
    private func hideSampleIndicators(in app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()

        let debugTools = app.buttons["Debug tools"]
        XCTAssertTrue(
            scrollTo(debugTools, in: app),
            "Settings → Developer → Debug tools not found. Was the build made with ZW_DEBUG_TOOLS=YES?"
        )
        debugTools.tap()

        let toggle = app.switches["Hide sample indicators"]
        XCTAssertTrue(scrollTo(toggle, in: app), "'Hide sample indicators' toggle not found.")
        XCTAssertTrue(switchOn(toggle), "'Hide sample indicators' did not switch on.")

        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Switches a toggle on and waits for the change to land.
    ///
    /// A plain `.tap()` on a SwiftUI `Toggle` inside a `Form` lands on the row
    /// rather than the control, which leaves the value unchanged, so fall back
    /// to tapping the trailing edge where the switch actually is. The value is
    /// polled because the accessibility value updates a beat after the tap.
    private func switchOn(_ toggle: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        func isOn() -> Bool { (toggle.value as? String) == "1" }
        if isOn() { return true }

        for attempt in 0..<2 {
            if attempt == 0 {
                toggle.tap()
            } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if isOn() { return true }
                usleep(100_000)
            }
        }
        return isOn()
    }

    /// Swipes until `element` is hittable. Form rows below the fold are present
    /// in the tree but not tappable until scrolled into view.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 5) && element.isHittable { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
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
