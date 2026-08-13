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

        let widgetsTab = navigationButton(named: "Widgets", in: app)
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

        prepareHomeScreenWidgets()
        app.activate()

        if captureActivities(in: app) {
            // Backgrounding surfaces the activity in the Dynamic Island, which
            // is the only way to see it — it does not render while the app is
            // foremost.
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 3)

            // Always reach the dedicated marketing page from the first page so
            // the capture is independent of which page a previous run left open.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for _ in 0..<5 { springboard.swipeRight() }
            for _ in 0..<marketingPageIndex(in: springboard) {
                springboard.swipeLeft()
            }
            Thread.sleep(forTimeInterval: 3)

            let homeWidgets = springboard.descendants(matching: .icon)
                .matching(identifier: "00Widget")
                .allElementsBoundByIndex
            XCTAssertTrue(
                homeWidgets.filter { isSmallWidget($0) }.count == 3,
                "The marketing page must contain exactly three small 00Widget widgets."
            )
            if isIPad(springboard) {
                XCTAssertFalse(
                    testRunnerIcon(in: springboard).exists,
                    "The UI test runner must not appear in a marketing screenshot."
                )
                // iPad has no Dynamic Island. Its applicable Home Screen shot
                // is the three-widget layout without an island presentation.
                capture(named: "screenshot-home-widgets")
            } else {
                capture(named: "screenshot-home-dynamic-island")

                // Long-press the island to reach the expanded presentation,
                // which is what the published iPhone screenshot shows.
                springboard
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.022))
                    .press(forDuration: 1.2)
                Thread.sleep(forTimeInterval: 2)
                capture(named: "screenshot-home-widgets")
            }
        }
    }

    /// Fast path for an app-only Activities refresh. It avoids rebuilding the
    /// Home Screen widget layout when that marketing surface has not changed.
    func testCaptureActivitiesScreenshot() throws {
        let app = XCUIApplication()
        app.launch()

        let activitiesTab = navigationButton(named: "Activities", in: app)
        XCTAssertTrue(
            activitiesTab.waitForExistence(timeout: 30),
            "Navigation never appeared — the app may have failed to launch."
        )
        hideSampleIndicators(in: app)
        XCTAssertTrue(captureActivities(in: app), "Activities tab did not appear.")
    }

    @discardableResult
    private func captureActivities(in app: XCUIApplication) -> Bool {
        let activitiesTab = navigationButton(named: "Activities", in: app)
        guard activitiesTab.waitForExistence(timeout: 5) else { return false }
        activitiesTab.tap()

        // Start a local sample so the tab shows a running activity rather than
        // its empty state. Only push-started activities require APNs.
        let generateActivity = app.buttons["Generate sample activity"]
        if generateActivity.waitForExistence(timeout: 5) {
            generateActivity.tap()
        }

        XCTAssertTrue(
            app.staticTexts["Washing machine"].waitForExistence(timeout: 15),
            "Sample Live Activity did not start."
        )
        capture(named: "screenshot-activities")
        return true
    }

    /// Replaces the retained layout with three screenshot-only small widgets.
    /// One existing widget stays until all three are added so SpringBoard does
    /// not delete the otherwise-empty dedicated page.
    private func prepareHomeScreenWidgets() {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<5 { springboard.swipeRight() }
        for _ in 0..<marketingPageIndex(in: springboard) {
            springboard.swipeLeft()
        }

        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7))
            .press(forDuration: 1.2)
        XCTAssertTrue(springboard.buttons["Edit"].waitForExistence(timeout: 5))

        let existing = marketingWidgets(in: springboard)
        let hasNonSmall = existing.contains { !isSmallWidget($0) }
        let smallCount = existing.filter { isSmallWidget($0) }.count
        // The iPad page also contains apps, so removing every widget cannot
        // delete it. The iPhone marketing page is widget-only and needs one
        // temporary anchor to survive while its layout is rebuilt.
        let keepSmallAnchor = !isIPad(springboard) && !hasNonSmall && smallCount > 0
        let smallsToRemove = keepSmallAnchor ? smallCount - 1 : smallCount
        for _ in 0..<smallsToRemove {
            removeWidget(in: springboard, matching: isSmallWidget)
        }

        if isIPad(springboard) {
            // iPad preserves insertion order.
            addWidget(named: "Screenshot Solar", in: springboard)
            addWidget(named: "Screenshot Washer", in: springboard)
            addWidget(named: "Screenshot Boiler", in: springboard)
        } else {
            // iPhone inserts each addition at the front, so add in reverse.
            addWidget(named: "Screenshot Boiler", in: springboard)
            addWidget(named: "Screenshot Washer", in: springboard)
            addWidget(named: "Screenshot Solar", in: springboard)
        }

        if keepSmallAnchor {
            removeWidget(in: springboard, matching: isSmallWidget, last: true)
        }
        if hasNonSmall {
            removeWidget(in: springboard) { !isSmallWidget($0) }
        }
        if isIPad(springboard) {
            hideTestRunnerIconIfPresent(in: springboard)
        }

        springboard.buttons["Done"].tap()
        Thread.sleep(forTimeInterval: 2)
    }

    /// Xcode installs the UI test runner as a separate app. On iPadOS it can
    /// land on the same regular Home Screen page as the marketing widgets.
    /// Removing it from the Home Screen keeps the running test installed and
    /// moves its launcher to App Library, so capture can continue normally.
    private func hideTestRunnerIconIfPresent(in springboard: XCUIApplication) {
        let runner = testRunnerIcon(in: springboard)
        guard runner.exists else { return }

        let removeControl = runner.buttons["DeleteButton"]
        XCTAssertTrue(removeControl.waitForExistence(timeout: 5))
        removeControl.tap()

        let removeFromHomeScreen = springboard.buttons["Remove from Home Screen"]
        XCTAssertTrue(
            removeFromHomeScreen.waitForExistence(timeout: 5),
            "iPadOS did not offer to remove the UI test runner from the Home Screen."
        )
        removeFromHomeScreen.tap()
        XCTAssertFalse(runner.waitForExistence(timeout: 2))
    }

    private func testRunnerIcon(in springboard: XCUIApplication) -> XCUIElement {
        springboard.descendants(matching: .icon)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ZeroZeroWidget'"))
            .firstMatch
    }

    private func removeWidget(
        in springboard: XCUIApplication,
        matching predicate: (XCUIElement) -> Bool,
        last: Bool = false
    ) {
        let matches = marketingWidgets(in: springboard).filter(predicate)
        let widget = last ? matches.max(by: isEarlierOnHomeScreen) : matches.first
        XCTAssertNotNil(widget, "Expected retained 00Widget widget was not found.")
        widget?.buttons["DeleteButton"].tap()
        XCTAssertTrue(springboard.buttons["Remove"].waitForExistence(timeout: 5))
        springboard.buttons["Remove"].tap()
        Thread.sleep(forTimeInterval: 1)
    }

    private func marketingWidgets(in springboard: XCUIApplication) -> [XCUIElement] {
        springboard.descendants(matching: .icon)
            .matching(identifier: "00Widget")
            .allElementsBoundByIndex
            .filter { $0.frame.width > 120 }
    }

    private func isSmallWidget(_ widget: XCUIElement) -> Bool {
        widget.frame.width > 120 && widget.frame.width / widget.frame.height < 1.3
    }

    private func isIPad(_ application: XCUIApplication) -> Bool {
        application.frame.width > 600
    }

    private func marketingPageIndex(in springboard: XCUIApplication) -> Int {
        // The leftmost position is Today View on both devices. The iPad's
        // second regular page avoids the large preinstalled Apple widgets.
        isIPad(springboard) ? 2 : 3
    }

    /// SwiftUI exposes the same navigation as tab-bar buttons on iPhone and
    /// ordinary buttons in iPad's floating top bar. A descendant button query
    /// works for both presentations.
    private func navigationButton(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: name).firstMatch
    }

    private func isEarlierOnHomeScreen(_ lhs: XCUIElement, _ rhs: XCUIElement) -> Bool {
        if abs(lhs.frame.minY - rhs.frame.minY) > 1 {
            return lhs.frame.minY < rhs.frame.minY
        }
        return lhs.frame.minX < rhs.frame.minX
    }

    private func addWidget(named name: String, in springboard: XCUIApplication) {
        springboard.buttons["Edit"].tap()
        XCTAssertTrue(springboard.buttons["Add Widget"].waitForExistence(timeout: 5))
        springboard.buttons["Add Widget"].tap()

        let search = springboard.searchFields["Search Widgets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("00Widget")

        let result = springboard.cells["00Widget"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()

        let targetTitle = springboard.staticTexts[name]
        for _ in 0..<16 where !targetTitle.exists {
            let preview = springboard.buttons.matching(
                NSPredicate(format: "value CONTAINS 'Widget'")
            ).firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            preview.swipeLeft()
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(targetTitle.exists, "Widget picker never reached \(name).")

        let add = springboard.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Add Widget'")
        ).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(springboard.buttons["Done"].waitForExistence(timeout: 5))
    }

    /// Turns off the "SAMPLE" badges and the "these are samples" notices via
    /// Settings → Developer, so the shots show the product rather than the
    /// labelling. The Developer section only exists because
    /// `capture-screenshots.sh` builds with `ZW_DEBUG_TOOLS=YES`; a shipping
    /// build has no such screen and no way to reach this flag.
    private func hideSampleIndicators(in app: XCUIApplication) {
        let settingsTab = navigationButton(named: "Settings", in: app)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30))
        settingsTab.tap()

        let debugTools = app.buttons["Debug tools"]
        XCTAssertTrue(
            scrollTo(debugTools, in: app),
            "Settings → Developer → Debug tools not found. Was the build made with ZW_DEBUG_TOOLS=YES?"
        )
        debugTools.tap()

        let toggle = app.switches["Hide sample indicators"]
        XCTAssertTrue(scrollTo(toggle, in: app), "'Hide sample indicators' toggle not found.")
        XCTAssertTrue(switchOn(toggle), "'Hide sample indicators' did not switch on.")

        // Refresh timestamps even when a previous run's samples are still in
        // the App Group. Otherwise the retained Home Screen widgets correctly
        // label that old cache as stale in the marketing screenshot.
        let generate = app.buttons["Generate sample cards"]
        XCTAssertTrue(scrollTo(generate, in: app), "'Generate sample cards' button not found.")
        generate.tap()

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
