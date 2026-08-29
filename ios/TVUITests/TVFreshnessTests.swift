import XCTest

/// "Updated 18 seconds ago" is a string, computed once, at whatever moment
/// something else caused a redraw. The Apple TV dashboard redraws when a fetch
/// returns and hardly ever otherwise, so the line sat unchanged for a whole
/// refresh interval and then jumped to "38 seconds ago" — invisible while the
/// wording is in minutes, and impossible to miss while it is in seconds.
///
/// This is testable precisely because a `ZW_SCREENSHOTS` build never syncs:
/// `startupSync` returns immediately, so nothing fetches, nothing publishes,
/// and the clock is the only thing left that can move the text.
///
///     xcodebuild test -project ios/ZeroZeroWidget.xcodeproj \
///       -scheme ZeroZeroWidgetTVScreenshots \
///       -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)' \
///       -only-testing:ZeroZeroWidgetTVUITests/TVFreshnessTests \
///       CODE_SIGNING_ALLOWED=NO \
///       SWIFT_ACTIVE_COMPILATION_CONDITIONS="ZW_SHARING_ENABLED ZW_SCREENSHOTS"
final class TVFreshnessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTheUpdatedLineCountsUpWithNothingFetching() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-section", "all"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Home battery"].waitForExistence(timeout: 30),
            "Sample Live Activity did not render on Apple TV."
        )
        // The detail panel, which is the surface the line is largest on. Its
        // header is plain text rather than a collapsed button label, so the
        // string itself is queryable.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["Close"].waitForExistence(timeout: 10),
            "Pressing Select did not open the detail panel."
        )

        XCTAssertTrue(updated(in: app).waitForExistence(timeout: 10), "No \"Updated…\" line on the panel.")
        let first = updated(in: app).label

        var latest = first
        let deadline = Date().addingTimeInterval(20)
        while latest == first && Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            latest = updated(in: app).label
        }

        XCTAssertNotEqual(
            latest, first,
            "The relative timestamp never moved on its own. Nothing fetches in "
                + "this build, so it will only ever change when something else "
                + "provokes a redraw — which on a television is a refresh "
                + "interval later, in one visible jump."
        )
    }

    private func updated(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Updated"))
            .firstMatch
    }
}
