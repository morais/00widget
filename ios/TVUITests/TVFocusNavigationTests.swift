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
            app.staticTexts["Home battery"].waitForExistence(timeout: 30),
            "Sample Live Activity did not render on Apple TV."
        )
        XCTAssertTrue(
            focusedLabel(in: app).contains("Home battery"),
            "Expected the Live Activity card to start focused, found: \(focusedLabel(in: app))"
        )

        XCUIRemote.shared.press(.down)

        let deadline = Date().addingTimeInterval(10)
        var label = focusedLabel(in: app)
        while label.contains("Home battery") && Date() < deadline {
            label = focusedLabel(in: app)
        }

        XCTAssertFalse(
            label.isEmpty,
            "Pressing down left nothing focused at all."
        )
        XCTAssertFalse(
            label.contains("Home battery"),
            "Focus never left the Live Activity card, so the Widgets section "
                + "below it cannot be reached."
        )
    }

    private func focusedLabel(in app: XCUIApplication) -> String {
        app.descendants(matching: .any)
            .allElementsBoundByIndex
            .first(where: \.hasFocus)?
            .label ?? ""
    }
}
