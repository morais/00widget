import XCTest

/// Stages the App Store Preview hero page on the marketing Simulator.
///
/// The preview timeline films a prepared SpringBoard stage: three small
/// launch widgets plus the wide Trials chart alone on one widget-only page,
/// with the `App launch` Live Activity on the island. Widget placement has no
/// `simctl` verb and Simulator exposes no accessibility windows, so like the
/// screenshots this drives SpringBoard's own widget gallery with XCUITest.
///
/// Run deliberately via
/// `marketing/app-preview/run.sh ios-main --stage-device` — never as part of
/// a capture, which must film the stage without rearranging it.
///
/// Two SpringBoard facts shape this test. Queries span every page, so all
/// counting is scoped to the visible screen bounds rather than trusting a
/// global total. And a freed page vanishes, so the flow sweeps the device
/// clean, births exactly one page by dragging, and never empties it again.
final class PreviewStageTests: XCTestCase {
    private let heroWidgets = [
        "Preview Launch",
        "Preview Production",
        "Preview Open PRs",
        "Preview Trials Wide",
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testStagePreviewHero() throws {
        let app = XCUIApplication()
        // A previous run can leave the app suspended; activating it would
        // resume without launch arguments and land on Settings instead of the
        // marketing demo. Terminate first so this launch carries its args,
        // and let the old process finish dying before launching, or the new
        // launch can attach to it instead.
        app.terminate()
        Thread.sleep(forTimeInterval: 2)
        app.launchArguments = [
            "--marketing-demo",
            "--marketing-reference-date", "2026-09-01T09:41:00Z",
            "--preview-launch-phase", "a",
        ]
        app.launch()
        if !app.staticTexts["Launch"].firstMatch.waitForExistence(timeout: 60) {
            // The launch arguments sometimes do not reach a freshly installed
            // app on a loaded simulator. Shoot what is on screen, then try
            // once more from terminated rather than failing a 15-minute run
            // on a 60-second phenomenon.
            let missed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            missed.name = "preview-stage-launch-miss"
            missed.lifetime = .keepAlways
            add(missed)
            print("STAGE first launch missed the demo cards; relaunching once")
            app.terminate()
            Thread.sleep(forTimeInterval: 2)
            app.launch()
        }
        XCTAssertTrue(
            app.staticTexts["Launch"].firstMatch.waitForExistence(timeout: 60),
            "Preview launch cards did not load; use a ZW_SCREENSHOTS build."
        )
        // Give WidgetCenter's explicit reload time to settle before SpringBoard
        // snapshots the placed widgets.
        Thread.sleep(forTimeInterval: 2)

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        XCTAssertFalse(isIPad(springboard), "Preview staging targets the iPhone hero page.")

        // Start from a known page: the frontmost page after a previous run
        // can be anywhere, and a long-press there may offer no editing.
        for _ in 0..<8 { springboard.swipeRight() }
        springboard.swipeLeft()
        enterHomeScreenEditing(in: springboard)
        sweepPreviewWidgets(in: springboard)
        if springboard.buttons["Done"].exists {
            springboard.buttons["Done"].tap()
            Thread.sleep(forTimeInterval: 1)
        }

        createPreviewPage(in: springboard)
        XCTAssertEqual(currentPageWidgets(in: springboard).count, 1)

        enterHomeScreenEditing(in: springboard)
        for name in heroWidgets.dropFirst() {
            addAndVerifyWidget(named: name, in: springboard)
        }
        if springboard.buttons["Done"].exists {
            springboard.buttons["Done"].tap()
            Thread.sleep(forTimeInterval: 2)
        }

        // Settle, then shoot the proof before asserting: on failure the
        // attachment is the diagnosis, and there is no second chance to take
        // it after the run tears down.
        Thread.sleep(forTimeInterval: 5)
        let hero = currentPageWidgets(in: springboard)
        print("STAGE hero widgets: \(hero.map { "\($0.frame)" })")
        let proof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        proof.name = "preview-stage-hero"
        proof.lifetime = .keepAlways
        add(proof)

        XCTAssertEqual(hero.count, 4, "The hero page must contain exactly four 00Widget widgets.")
        XCTAssertEqual(
            hero.filter { isSmallWidget($0) }.count,
            3,
            "The hero page must contain three small widgets."
        )
        if let wide = hero.first(where: { !isSmallWidget($0) }) {
            XCTAssertTrue(
                wide.frame.width > wide.frame.height,
                "The fourth hero widget must be the wide Trials chart."
            )
        }
        let strangers = currentPageIcons(in: springboard).filter {
            $0.identifier != "00Widget" && $0.frame.maxY < 740
        }
        XCTAssertTrue(
            strangers.isEmpty,
            "The hero page must hold only preview widgets."
        )

        // The camera finds the hero by ordinary page index, so report it for
        // stage.initialPage in the preview config.
        for _ in 0..<8 { springboard.swipeRight() }
        springboard.swipeLeft()
        for index in 0..<8 {
            if currentPageWidgets(in: springboard).count >= 4 {
                print("STAGE hero page ordinary index: \(index)")
                break
            }
            if index < 7 { springboard.swipeLeft() }
        }
    }

    /// Removes every 00Widget widget on every page. Bounded: each pass visits
    /// each page once, and an emptying page vanishes underfoot, so the loop
    /// ends when a full sweep finds nothing or the budget runs out.
    private func sweepPreviewWidgets(in springboard: XCUIApplication) {
        for _ in 0..<8 { springboard.swipeRight() }
        for _ in 0..<10 {
            var removed = false
            for page in 0..<8 {
                for _ in 0..<6 {
                    // Re-query after every removal: the hierarchy animates
                    // underfoot and a previously fetched element goes stale.
                    // Only the frame crosses into the removal; CGRect cannot
                    // go stale.
                    Thread.sleep(forTimeInterval: 2)
                    guard let frame = currentPageWidgets(in: springboard).first?.frame else { break }
                    removeHomeScreenWidget(frame, in: springboard)
                    removed = true
                }
                if page < 7 { springboard.swipeLeft() }
            }
            if !removed { return }
        }
        XCTFail("Widget sweep did not converge; preview widgets remain.")
    }

    /// Bootstraps the widget-only hero page by carrying a temporary preview
    /// widget right past the existing pages; SpringBoard creates a new page
    /// to receive it without moving any app icons. The temporary widget is
    /// the first hero widget, so nothing added here is ever removed.
    ///
    /// Closed-loop: the page dots report "page X of Y", so each drag must
    /// grow the page count or fail loudly. Blind drags cost a 15-minute loop
    /// to discover they never paginated.
    private func createPreviewPage(in springboard: XCUIApplication) {
        for _ in 0..<8 { springboard.swipeRight() }
        springboard.swipeLeft()
        enterHomeScreenEditing(in: springboard)
        addWidget(named: heroWidgets[0], in: springboard)

        for drag in 0..<8 {
            let pagesBefore = pageCount(in: springboard)
            guard currentPageWidgets(in: springboard).first != nil else {
                XCTFail("The temporary preview widget disappeared while creating its page.")
                return
            }
            currentPageWidgets(in: springboard).first!
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(
                    forDuration: 1.0,
                    thenDragTo: springboard.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.98, dy: 0.45)
                    ),
                    withVelocity: 800,
                    thenHoldForDuration: 1.0
                )
            Thread.sleep(forTimeInterval: 1)
            let pagesAfter = pageCount(in: springboard)
            print("STAGE page-creating drag \(drag): \(pagesBefore as Any) -> \(pagesAfter as Any) pages")
            if let pagesAfter, let pagesBefore, pagesAfter > pagesBefore {
                break
            }
        }

        XCTAssertTrue(springboard.buttons["Done"].waitForExistence(timeout: 5))
        springboard.buttons["Done"].tap()
        Thread.sleep(forTimeInterval: 2)
    }

    /// Adds one gallery widget and waits for it to land on this page. A drop
    /// onto an animating slot silently stacks instead of adding, and only a
    /// page-local count can tell.
    private func addAndVerifyWidget(named name: String, in springboard: XCUIApplication) {
        let before = currentPageWidgets(in: springboard).count
        addWidget(named: name, in: springboard)
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<30 {
            if currentPageWidgets(in: springboard).count == before + 1 {
                print("STAGE added \(name): page now holds \(before + 1) widgets")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        scanWidgetPages(in: springboard)
        XCTFail("The gallery accepted \(name) but this page gained no widget.")
    }

    /// Logs every page's widgets so a gallery add that lands somewhere
    /// unexpected can be found instead of theorized about.
    private func scanWidgetPages(in springboard: XCUIApplication) {
        Thread.sleep(forTimeInterval: 3)
        for _ in 0..<8 { springboard.swipeRight() }
        for page in 0..<8 {
            print("STAGE scan page \(page): \(currentPageWidgets(in: springboard).map { "\($0.frame)" })")
            if page < 7 {
                springboard.swipeLeft()
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// Parses "page X of Y" from the Home Screen dots, or nil when they
    /// cannot be read on this configuration.
    private func pageCount(in springboard: XCUIApplication) -> Int? {
        let dots = springboard.pageIndicators.firstMatch
        guard dots.exists, let value = dots.value as? String else { return nil }
        let parts = value.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
        guard parts.count == 2 else { return nil }
        return parts[1]
    }

    private func enterHomeScreenEditing(in springboard: XCUIApplication) {
        // A previous attempt can die with the app-removal dialog open; its
        // Cancel is the only thing that leads back to the Home Screen.
        if springboard.alerts.firstMatch.waitForExistence(timeout: 2) {
            let cancel = springboard.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() }
        }
        // A previous attempt can die mid-jiggle; landing back in editing
        // mode with Done showing and no Edit to tap. That is already where
        // this needs to be, not a state to fight.
        if springboard.buttons["Done"].exists { return }
        // A press can land on the dock, Search, or a menu that never offers
        // editing. Vary the spot and retry rather than failing the run on one
        // dead press.
        let spots = [
            CGVector(dx: 0.7, dy: 0.7),
            CGVector(dx: 0.3, dy: 0.5),
            CGVector(dx: 0.5, dy: 0.3),
        ]
        for spot in spots {
            springboard.coordinate(withNormalizedOffset: spot).press(forDuration: 1.2)
            if springboard.buttons["Edit"].waitForExistence(timeout: 2) { return }
            let editHomeScreen = springboard.buttons["Edit Home Screen"]
            if editHomeScreen.waitForExistence(timeout: 2) {
                editHomeScreen.tap()
                if springboard.buttons["Edit"].waitForExistence(timeout: 5) { return }
            }
        }
        XCTFail("Could not enter Home Screen editing.")
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

    private func removeHomeScreenWidget(
        _ frame: CGRect,
        in springboard: XCUIApplication
    ) {
        // Tap by coordinate, never through a retained element: page vanishes
        // re-index the hierarchy mid-sweep and a held reference resolves
        // against pages that no longer exist. The minus badge sits just
        // outside the widget's top-left corner; a miss taps empty jiggle
        // space, which is harmless, and the loop tries again.
        var sheet = false
        for _ in 0..<3 {
            let size = springboard.frame.size
            guard frame.width > 0, size.width > 0 else { break }
            springboard.coordinate(
                withNormalizedOffset: CGVector(
                    dx: (frame.minX - 12) / size.width,
                    dy: (frame.minY - 12) / size.height
                )
            ).tap()
            let remove = springboard.buttons
                .matching(NSPredicate(format: "label == 'Remove' OR label == 'Remove Widget'"))
                .firstMatch
            if remove.waitForExistence(timeout: 8) {
                remove.tap()
                sheet = true
                break
            }
        }
        if !sheet {
            let stuck = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            stuck.name = "preview-stage-remove-stuck"
            stuck.lifetime = .keepAlways
            add(stuck)
        }
        XCTAssertTrue(sheet, "Removing a staged widget never offered Remove.")
        Thread.sleep(forTimeInterval: 1)
    }

    /// Every icon SpringBoard reports, scoped to the visible page. Queries
    /// span all pages, so the screen bounds are the page.
    private func currentPageIcons(in springboard: XCUIApplication) -> [XCUIElement] {
        let bounds = springboard.frame
        return springboard.descendants(matching: .icon).allElementsBoundByIndex.filter { icon in
            let frame = icon.frame
            return frame.width > 40
                && frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1
                && frame.minY >= bounds.minY - 1 && frame.maxY <= bounds.maxY + 1
        }
    }

    private func currentPageWidgets(in springboard: XCUIApplication) -> [XCUIElement] {
        // Identifier alone is not enough: the 00Widget app icon and the UI
        // test runner icon report the same "00Widget" identifier as the
        // widgets. Widgets are an order of magnitude wider than the ~60pt
        // app icons, so the width floor keeps the sweep from ever offering
        // to delete the app itself.
        currentPageIcons(in: springboard).filter {
            $0.identifier == "00Widget" && $0.frame.width > 120
        }
    }

    private func isSmallWidget(_ widget: XCUIElement) -> Bool {
        widget.frame.width < 250 && widget.frame.height < 250
    }

    private func isIPad(_ application: XCUIApplication) -> Bool {
        application.frame.width > 600
    }
}
