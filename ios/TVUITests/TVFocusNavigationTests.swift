import XCTest

/// tvOS moves focus only to views that exist, and a `LazyVGrid` does not build
/// what is off screen. That combination made the Widgets section unreachable
/// the moment a Live Activity card grew tall enough to push it past the bottom
/// of the screen: pressing down found nothing to focus, focus stayed put, the
/// scroll view never scrolled, and the row that would then have been built
/// never was. It shipped to TestFlight and only a television showed it.
///
/// Run it directly; the marketing capture script does not:
///
///     xcodebuild test -project ios/ZeroZeroWidget.xcodeproj \
///       -scheme ZeroZeroWidgetTVScreenshots \
///       -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)' \
///       -only-testing:ZeroZeroWidgetTVUITests/TVFocusNavigationTests \
///       CODE_SIGNING_ALLOWED=NO \
///       SWIFT_ACTIVE_COMPILATION_CONDITIONS="ZW_SHARING_ENABLED ZW_SCREENSHOTS"
final class TVFocusNavigationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testFocusLeavesTheLiveActivityForTheWidgetsBelowIt() {
        let app = XCUIApplication()
        // The section whose activity carries item rows, so the Widgets section
        // starts off screen. With the short card the bug cannot appear.
        app.launchArguments = ["--screenshot-section", "focus"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["App launch"].waitForExistence(timeout: 30),
            "Sample Live Activity did not render on Apple TV."
        )
        XCTAssertTrue(
            focusedLabel(in: app).contains("App launch"),
            "Expected the Live Activity card to start focused, found: \(focusedLabel(in: app))"
        )

        XCUIRemote.shared.press(.down)

        let deadline = Date().addingTimeInterval(10)
        var label = focusedLabel(in: app)
        while label.contains("App launch") && Date() < deadline {
            label = focusedLabel(in: app)
        }

        XCTAssertFalse(
            label.isEmpty,
            "Pressing down left nothing focused at all."
        )
        XCTAssertFalse(
            label.contains("App launch"),
            "Focus never left the Live Activity card, so the Widgets section "
                + "below it cannot be reached."
        )
    }

    /// The mirror of the test above, and the second dead end this file has had
    /// to record. Focus could not leave the widget grid *upward*: nothing in
    /// the scrolling content lined up with the header, so pressing Up from the
    /// top row did nothing at all — ten presses, still on the first card — and
    /// Settings was unreachable. With it went sign out, the diagnostics, and
    /// the account deletion Apple requires an app to offer.
    ///
    /// It was reachable in exactly one configuration: a Live Activity card
    /// carried an `onMoveCommand` that shoved focus into the header, so the
    /// dashboard worked in the shape nobody has by default and failed in the
    /// ordinary one. The `widgets` section is that ordinary shape.
    func testFocusReachesSettingsFromTheWidgetGrid() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "widgets"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Launch"].waitForExistence(timeout: 30),
            "Sample widgets did not render on Apple TV."
        )
        let settings = app.buttons["Settings"]
        XCTAssertFalse(settings.hasFocus, "Expected the grid to start focused, not the header.")

        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            waitForFocus(settings, in: app),
            "Pressing up from the top row of widgets never reached Settings, so "
                + "sign out and account deletion cannot be reached at all. Focus "
                + "stayed on: \(focusedLabel(in: app))"
        )
    }

    /// The over-correction guard. A fix that sends every Up press to the header
    /// would pass the test above while making the grid itself unnavigable, so
    /// the second row has to reach the first row before it reaches Settings.
    func testUpFromTheSecondRowWalksTheGridFirst() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "widgets"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Launch"].waitForExistence(timeout: 30))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(
            waitForFocus(app.buttons["Settings"], in: app, expected: false, containing: "Support"),
            "Expected the second row to take focus, found: \(focusedLabel(in: app))"
        )

        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            waitForFocus(app.buttons["Settings"], in: app, expected: false, containing: "Launch"),
            "Up from the second row skipped the first row, found: \(focusedLabel(in: app))"
        )
    }

    /// The dashboard grid is a summary now: the action buttons and the link's
    /// QR code moved off the card and into a panel, so pressing Select is the
    /// only way to reach either. That makes the panel a focus dead end waiting
    /// to happen — if nothing inside it can take focus, the viewer is left on a
    /// screen with no visible way out, which is the same class of bug the two
    /// tests above record.
    func testSelectingACardOpensAPanelThatCanBeLeft() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "widgets"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Launch"].waitForExistence(timeout: 30),
            "Sample widgets did not render on Apple TV."
        )

        XCUIRemote.shared.press(.select)

        let close = app.buttons["Close"]
        XCTAssertTrue(
            close.waitForExistence(timeout: 10),
            "Pressing Select on a card did not open its detail panel."
        )
        XCTAssertTrue(
            waitForFocus(close, in: app),
            "The detail panel opened with nothing focused, so there is no way "
                + "out of it. Focus was on: \(focusedLabel(in: app))"
        )

        XCUIRemote.shared.press(.menu)
        // Let the cover finish going away before asking what has focus.
        // Enumerating the hierarchy mid-dismissal fails the snapshot outright
        // rather than returning a stale answer.
        XCTAssertTrue(
            close.waitForNonExistence(timeout: 10),
            "Menu did not dismiss the detail panel."
        )
        XCTAssertTrue(
            waitForFocus(app.buttons["Settings"], in: app, expected: false, containing: "Launch"),
            "Leaving the panel did not return focus to the card it was opened "
                + "from, found: \(focusedLabel(in: app))"
        )
    }

    /// The buttons the dashboard used to draw beside each card. They have to be
    /// reachable from the panel's own focus, not merely present in it.
    func testTheDetailPanelReachesTheCardsActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "widgets"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Launch"].waitForExistence(timeout: 30))
        // Launch is the first sample and carries the approval action.
        XCTAssertTrue(
            waitForFocus(app.buttons["Settings"], in: app, expected: false, containing: "Launch"),
            "Expected the Launch card to take focus, found: \(focusedLabel(in: app))"
        )

        XCUIRemote.shared.press(.select)
        let boost = app.buttons["Approve"]
        XCTAssertTrue(
            boost.waitForExistence(timeout: 10),
            "The detail panel did not draw the card's action."
        )

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(
            waitForFocus(boost, in: app),
            "Down from the panel header never reached the action button, so an "
                + "action can be seen and not run. Focus was on: \(focusedLabel(in: app))"
        )
    }

    private func waitForFocus(
        _ element: XCUIElement,
        in app: XCUIApplication,
        expected: Bool = true,
        containing text: String? = nil,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text {
                if focusedLabel(in: app).contains(text) { return true }
            } else if element.hasFocus == expected {
                return true
            }
            // Polling as fast as the loop can go means a full hierarchy
            // snapshot every few milliseconds, which is both wasteful and a
            // way to catch the app mid-transition.
            Thread.sleep(forTimeInterval: 0.1)
        }
        return text == nil ? element.hasFocus == expected : focusedLabel(in: app).contains(text!)
    }

    private func focusedLabel(in app: XCUIApplication) -> String {
        app.descendants(matching: .any)
            .allElementsBoundByIndex
            .first(where: \.hasFocus)?
            .label ?? ""
    }
}
