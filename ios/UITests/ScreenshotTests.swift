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
        prepareIPadMarketingDock(in: app)

        hideSampleIndicators(in: app)
        generateSampleWidgets(in: app)
        capture(named: "screenshot-widgets")
        captureInsights(in: app)

        prepareHomeScreenWidgets(displayNames: classicWidgetNames)
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
            XCTAssertTrue(
                navigateToMarketingPage(in: springboard),
                "The prepared marketing Home Screen page disappeared."
            )
            Thread.sleep(forTimeInterval: 3)

            let homeWidgets = springboard.descendants(matching: .icon)
                .matching(identifier: "00Widget")
                .allElementsBoundByIndex
                .filter { $0.frame.width > 120 }
            XCTAssertTrue(
                homeWidgets.count == 4
                    && homeWidgets.filter { isSmallWidget($0) }.count == 3,
                "The classic marketing page must contain three small widgets and one wide widget."
            )
            if isIPad(springboard) {
                XCTAssertFalse(
                    testRunnerIcon(in: springboard).exists,
                    "The UI test runner must not appear in a marketing screenshot."
                )
                capture(named: "screenshot-home-widgets")
            } else if screenshotDeviceClass != "iphone-6.3" {
                // The 6.5-inch capture device has no Dynamic Island.
                capture(named: "screenshot-home-widgets")
            } else {
                // Long-press the island to reach the expanded presentation,
                // which is what the published iPhone screenshot shows.
                springboard
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.022))
                    .press(forDuration: 1.2)
                Thread.sleep(forTimeInterval: 2)
                capture(named: "screenshot-home-widgets")
            }

            app.activate()
            prepareHomeScreenWidgets(displayNames: insightWidgetNames)
            let insightWidgets = marketingWidgets(in: springboard)
            XCTAssertEqual(
                insightWidgets.count,
                3,
                "The insights page must contain exactly three widgets."
            )
            XCTAssertEqual(
                insightWidgets.filter { isSmallWidget($0) }.count,
                2,
                "The insights page must contain two small widgets."
            )
            XCTAssertEqual(
                insightWidgets.filter { isLargeWidget($0) }.count,
                1,
                "The insights page must contain one large widget."
            )
            capture(named: "screenshot-home-insights")

            app.activate()
            prepareHomeScreenWidgets(displayNames: metricWidgetNames)
            let metricWidgets = marketingWidgets(in: springboard)
            XCTAssertEqual(
                metricWidgets.count,
                1,
                "The metrics page must contain exactly one widget."
            )
            if isIPad(springboard) {
                XCTAssertEqual(
                    metricWidgets.filter { isExtraLargeWidget($0) }.count,
                    1,
                    "The iPad metrics page must contain one extra-large widget."
                )
            } else {
                XCTAssertEqual(
                    metricWidgets.filter { isLargeWidget($0) }.count,
                    1,
                    "The iPhone metrics page must contain one large widget."
                )
            }
            capture(named: "screenshot-home-metrics")
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

    /// Captures the app surfaces without depending on a particular SpringBoard
    /// page layout. This is useful for legacy App Store display classes whose
    /// simulator Home Screen differs from the current marketing device.
    func testCaptureAppScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        let widgetsTab = navigationButton(named: "Widgets", in: app)
        XCTAssertTrue(
            widgetsTab.waitForExistence(timeout: 30),
            "Navigation never appeared — the app may have failed to launch."
        )
        hideSampleIndicators(in: app)
        generateSampleWidgets(in: app)
        capture(named: "screenshot-widgets")
        captureInsights(in: app)
        XCTAssertTrue(captureActivities(in: app), "Activities tab did not appear.")
    }

    @discardableResult
    private func captureActivities(in app: XCUIApplication) -> Bool {
        let activitiesTab = navigationButton(named: "Activities", in: app)
        guard activitiesTab.waitForExistence(timeout: 5) else { return false }
        activitiesTab.tap()

        // The private screenshot build replaces any retained local sample when
        // this screen opens, so a previous capture cannot leave stale content.
        XCTAssertTrue(
            app.staticTexts["Home battery"].waitForExistence(timeout: 15),
            "Sample Live Activity did not start."
        )
        capture(named: "screenshot-activities")
        return true
    }

    private func captureInsights(in app: XCUIApplication) {
        let energy = app.staticTexts["Energy"].firstMatch
        XCTAssertTrue(scrollTo(energy, in: app, swipes: 10), "Energy sample card not found.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            )
        XCTAssertTrue(app.staticTexts["Deploys"].firstMatch.waitForExistence(timeout: 5))
        capture(named: "screenshot-insights")
    }

    private var classicWidgetNames: [String] {
        ["Screenshot Solar", "Screenshot Nightly Run", "Screenshot Boiler", "Screenshot Energy Wide"]
    }

    private var insightWidgetNames: [String] {
        ["Screenshot Energy Large", "Screenshot Deploys", "Screenshot Device Fleet"]
    }

    private var metricWidgetNames: [String] {
        if screenshotDeviceClass == "ipad" {
            return ["Screenshot Four Metrics Extra Large"]
        }
        return ["Screenshot Four Metrics Large"]
    }

    private var screenshotDeviceClass: String {
        ProcessInfo.processInfo.environment["ZW_SCREENSHOT_DEVICE_CLASS"] ?? "iphone-6.3"
    }

    /// Replaces the retained layout with the requested screenshot-only widgets.
    /// One existing widget stays until the first replacement is added so SpringBoard does
    /// not delete the otherwise-empty dedicated page.
    private func prepareHomeScreenWidgets(displayNames: [String]) {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if !navigateToMarketingPage(in: springboard) {
            createMarketingPage(in: springboard)
            XCTAssertTrue(
                navigateToMarketingPage(in: springboard),
                "The marketing Home Screen page could not be created."
            )
        }

        enterHomeScreenEditing(in: springboard)

        // A fresh iPhone simulator ships with Maps and Calendar widgets on its
        // widget page. Reuse that page, but clear those system widgets so the
        // classic layout has room for three small cards and the wide Energy
        // chart. App icons are excluded by the widget-sized frame filter.
        if !isIPad(springboard) {
            for widget in homeScreenWidgets(in: springboard)
                .filter({ $0.identifier != "00Widget" })
            {
                removeHomeScreenWidget(widget, in: springboard)
            }
        }

        let existing = marketingWidgets(in: springboard)
        let onIPad = isIPad(springboard)
        var anchorIsSmall: Bool?
        if onIPad {
            // Apps keep an iPad page alive, so it needs no temporary widget.
            for _ in existing.indices {
                removeWidget(in: springboard) { _ in true }
            }
        } else {
            let smallCount = existing.filter { isSmallWidget($0) }.count
            let nonSmallCount = existing.count - smallCount
            if smallCount > 0 {
                // Retain one small anchor and remove wider widgets first. A
                // retained medium widget plus the new large insights layout
                // exceeds an iPhone page's capacity before cleanup can run.
                for _ in 0..<nonSmallCount {
                    removeWidget(in: springboard) { !isSmallWidget($0) }
                }
                for _ in 0..<(smallCount - 1) {
                    removeWidget(in: springboard, matching: isSmallWidget)
                }
                anchorIsSmall = true
            } else if nonSmallCount > 0 {
                for _ in 0..<(nonSmallCount - 1) {
                    removeWidget(in: springboard) { !isSmallWidget($0) }
                }
                anchorIsSmall = false
            }
        }

        let insertionOrder = onIPad ? displayNames : Array(displayNames.reversed())
        for (index, name) in insertionOrder.enumerated() {
            addWidget(named: name, in: springboard)
            if let anchorIsSmall, index == 0 {
                // Once a replacement exists, the page no longer needs the old
                // widget as an anchor. At this point it is still the last
                // retained widget of its size class in Home Screen order.
                removeWidget(
                    in: springboard,
                    matching: { isSmallWidget($0) == anchorIsSmall },
                    last: true
                )
            }
        }
        if onIPad {
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
        guard let widget else { return }
        removeHomeScreenWidget(widget, in: springboard)
    }

    private func removeHomeScreenWidget(
        _ widget: XCUIElement,
        in springboard: XCUIApplication
    ) {
        widget.buttons["DeleteButton"].tap()
        let remove = springboard.buttons
            .matching(NSPredicate(format: "label == 'Remove' OR label == 'Remove Widget'"))
            .firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        remove.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    private func homeScreenWidgets(in springboard: XCUIApplication) -> [XCUIElement] {
        springboard.descendants(matching: .icon)
            .allElementsBoundByIndex
            .filter { $0.frame.width > 120 }
    }

    private func marketingWidgets(in springboard: XCUIApplication) -> [XCUIElement] {
        homeScreenWidgets(in: springboard)
            .filter { $0.identifier == "00Widget" }
    }

    private func isSmallWidget(_ widget: XCUIElement) -> Bool {
        widget.frame.width < 250 && widget.frame.height < 250
    }

    private func isLargeWidget(_ widget: XCUIElement) -> Bool {
        widget.frame.width >= 250 && widget.frame.height >= 250
    }

    private func isExtraLargeWidget(_ widget: XCUIElement) -> Bool {
        widget.frame.width >= 500 && widget.frame.height >= 250
    }

    private func isIPad(_ application: XCUIApplication) -> Bool {
        application.frame.width > 600
    }

    /// The iPad dock's App Library button previews recently hidden apps, which
    /// makes the installed UI-test runner look like an extra 00Widget icon.
    /// Turn off both optional dock sections through Settings so every fresh
    /// simulator produces the same clean Home Screen without private defaults.
    private func prepareIPadMarketingDock(in app: XCUIApplication) {
        guard isIPad(app) else { return }

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        let destination = settings.staticTexts["Home Screen & App Library"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        destination.tap()

        for label in ["Show App Library in Dock", "Show Suggested and Recent Apps in Dock"] {
            let toggle = settings.switches[label].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Settings toggle '\(label)' not found.")
            XCTAssertTrue(switchOff(toggle), "Settings toggle '\(label)' did not switch off.")
        }

        app.activate()
    }

    /// Finds the retained marketing page by its 00Widget widgets instead of by
    /// a fixed page number. SpringBoard renumbers pages when an ordinary page
    /// is added or removed; a hard-coded index can therefore land in App
    /// Library even though the dedicated widget page still exists.
    private func navigateToMarketingPage(in springboard: XCUIApplication) -> Bool {
        for _ in 0..<8 { springboard.swipeRight() }
        for page in 0..<8 {
            if !marketingWidgets(in: springboard).isEmpty { return true }
            if page < 7 { springboard.swipeLeft() }
        }
        return false
    }

    /// Bootstraps the otherwise-retained widget-only page after a simulator
    /// reset or after SpringBoard has deleted it. A temporary small widget is
    /// added to the first ordinary page, then carried right past the existing
    /// pages; SpringBoard creates a new page to receive it without moving or
    /// deleting any of the user's app icons.
    private func createMarketingPage(in springboard: XCUIApplication) {
        for _ in 0..<8 { springboard.swipeRight() }
        springboard.swipeLeft()
        enterHomeScreenEditing(in: springboard)
        addWidget(named: "Screenshot Solar", in: springboard)

        for _ in 0..<6 {
            guard let widget = marketingWidgets(in: springboard).first else {
                XCTFail("The temporary marketing widget disappeared while creating its page.")
                return
            }
            widget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(
                    forDuration: 0.8,
                    thenDragTo: springboard.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.98, dy: 0.45)
                    )
                )
            Thread.sleep(forTimeInterval: 1)
        }

        XCTAssertTrue(springboard.buttons["Done"].waitForExistence(timeout: 5))
        springboard.buttons["Done"].tap()
        Thread.sleep(forTimeInterval: 2)
    }

    private func enterHomeScreenEditing(in springboard: XCUIApplication) {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.7))
            .press(forDuration: 1.2)
        if !springboard.buttons["Edit"].waitForExistence(timeout: 2) {
            let editHomeScreen = springboard.buttons["Edit Home Screen"]
            XCTAssertTrue(editHomeScreen.waitForExistence(timeout: 3))
            editHomeScreen.tap()
        }
        XCTAssertTrue(springboard.buttons["Edit"].waitForExistence(timeout: 5))
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
        for _ in 0..<24 where !targetTitle.exists {
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

    /// Fills the dashboard by tapping its own empty-state button — the one a
    /// user taps — so the shots show a state a real user can reach.
    ///
    /// Always available, because a `ZW_SCREENSHOTS` build drops retained
    /// samples at launch and the dashboard therefore starts empty.
    private func generateSampleWidgets(in app: XCUIApplication) {
        let widgetsTab = navigationButton(named: "Widgets", in: app)
        XCTAssertTrue(widgetsTab.waitForExistence(timeout: 30))
        widgetsTab.tap()

        let generate = app.buttons["Generate sample widgets"]
        XCTAssertTrue(
            scrollTo(generate, in: app),
            "'Generate sample widgets' not found — was the dashboard already populated?"
        )
        generate.tap()
        XCTAssertTrue(
            app.staticTexts["Solar"].waitForExistence(timeout: 15),
            "Sample cards did not render after generating them."
        )
    }

    /// Turns off the "SAMPLE" badges and the "these are samples" notices so the
    /// shots show the product rather than the labelling.
    ///
    /// The flag lives on Settings → Developer, reached by tapping the version
    /// number and present in shipping builds — it is as useful for a screen
    /// recording as it is here. Nothing in a capture run reaches the debug
    /// console any more: both tabs replace their own samples on appearance
    /// under `ZW_SCREENSHOTS`.
    private func hideSampleIndicators(in app: XCUIApplication) {
        let settingsTab = navigationButton(named: "Settings", in: app)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30))
        settingsTab.tap()

        // The row reads "Version" plus the version string, so match the prefix
        // rather than a label that changes with every build.
        let versionRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Version'")
        ).firstMatch
        XCTAssertTrue(scrollTo(versionRow, in: app), "Settings → Version row not found.")
        versionRow.tap()

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

    private func switchOff(_ toggle: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        func isOff() -> Bool { (toggle.value as? String) == "0" }
        if isOff() { return true }

        for attempt in 0..<2 {
            if attempt == 0 {
                toggle.tap()
            } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if isOff() { return true }
                usleep(100_000)
            }
        }
        return isOff()
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

#if ZW_SUBSCRIPTIONS_ENABLED
    /// Photographs the paywall in each state the server can put it in.
    ///
    /// Subscription state is seeded through a launch argument rather than a
    /// live server, but the plan rows come from StoreKit against the scheme's
    /// .storekit configuration, so prices and trial text are real.
    func testCaptureSubscriptionScreenshots() throws {
        for state in ["none", "expired", "active"] {
            let app = XCUIApplication()
            app.launchArguments = ["-ZWSubscriptionState", state]
            app.launch()

            let settingsTab = navigationButton(named: "Settings", in: app)
            XCTAssertTrue(
                settingsTab.waitForExistence(timeout: 30),
                "Navigation never appeared for state \(state)."
            )
            settingsTab.tap()

            // The row's accessibility label is compound — "Subscription,
            // Expired" — because the NavigationLink wraps a label and a
            // status together, so an exact match never finds it. It sits in
            // the Server section rather than taking a section of its own.
            let row = app.buttons
                .containing(NSPredicate(format: "label BEGINSWITH 'Subscription'"))
                .firstMatch
            XCTAssertTrue(scrollTo(row, in: app, swipes: 10), "Subscription row not found.")
            XCTAssertTrue(
                app.staticTexts["Publishing data requires an active subscription."].exists,
                "Server section is missing the subscription requirement explanation."
            )
            capture(named: "screenshot-subscription-settings-\(state)")

            row.tap()
            XCTAssertTrue(
                app.staticTexts["Status"].waitForExistence(timeout: 10),
                "Subscription screen did not appear for state \(state)."
            )
            if state != "active" {
                let monthlyPlan = app.buttons
                    .containing(NSPredicate(format: "label BEGINSWITH 'Monthly'"))
                    .firstMatch
                XCTAssertTrue(
                    monthlyPlan.waitForExistence(timeout: 15),
                    "StoreKit plans did not load for state \(state)."
                )
            }
            scrollToTop(in: app)
            XCTAssertTrue(
                app.staticTexts["Subscription"].firstMatch.isHittable,
                "Subscription title is not visible for state \(state)."
            )
            capture(named: "screenshot-subscription-\(state)")
            app.terminate()
        }
    }

    /// The banner the dashboard shows while publishing is blocked.
    func testCaptureSubscriptionNotice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ZWSubscriptionState", "expired"]
        app.launch()

        let widgetsTab = navigationButton(named: "Widgets", in: app)
        XCTAssertTrue(widgetsTab.waitForExistence(timeout: 30), "Navigation never appeared.")
        widgetsTab.tap()

        // The empty dashboard first, before anything generates samples.
        // Someone who has never subscribed usually has nothing published, so
        // the empty dashboard is the branch the notice most needs to appear
        // in, and the one it was missing from.
        XCTAssertTrue(
            app.staticTexts["Publishing is paused"].waitForExistence(timeout: 15),
            "Subscription notice is missing from the empty dashboard."
        )
        XCTAssertTrue(
            app.buttons["Generate sample widgets"].exists,
            "Dashboard was not empty, so the empty-state branch went untested."
        )
        capture(named: "screenshot-subscription-notice-empty")

        // Then again with cards, where it has to sit above them.
        hideSampleIndicators(in: app)
        generateSampleWidgets(in: app)
        scrollToTop(in: app)
        XCTAssertTrue(
            app.staticTexts["Publishing is paused"].waitForExistence(timeout: 15)
                && app.staticTexts["Publishing is paused"].isHittable,
            "Subscription notice did not appear on the populated dashboard."
        )
        XCTAssertTrue(app.staticTexts["Solar"].exists, "Sample cards did not render.")
        capture(named: "screenshot-subscription-notice")
    }

    private func scrollToTop(in app: XCUIApplication) {
        for _ in 0..<6 {
            app.swipeDown()
        }
    }
#endif

    /// Captures the whole screen, not `app.screenshot()`, so the status bar is
    /// included — the published shots show it.
    private func capture(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
