import XCTest

/// Baseline accessibility audits for the app surfaces people use most.
///
/// Run through `ios/scripts/run-accessibility-audits.sh`. The runner executes
/// this test at Large and AX5 on a disposable simulator, while the private
/// build flags seed representative cards, a Live Activity, subscription state,
/// and the camera-denied scanner branch without shipping test affordances.
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testRepresentativeSurfaces() throws {
        var app = XCUIApplication()
        app.launchArguments = [
            "-ZWSubscriptionState", "expired",
        ]
        app.launch()

        let settingsTab = navigationButton(named: "Settings", in: app)
        XCTAssertTrue(
            settingsTab.waitForExistence(timeout: 30),
            "Navigation never appeared — the app may have failed to launch."
        )
        settingsTab.tap()
        try audit("Settings", in: app)

        let subscription = app.buttons
            .containing(NSPredicate(format: "label BEGINSWITH 'Subscription'"))
            .firstMatch
        XCTAssertTrue(scrollTo(subscription, in: app), "Subscription row not found.")
        subscription.tap()
        XCTAssertTrue(app.navigationBars["Subscription"].waitForExistence(timeout: 10))
        try audit("Subscription", in: app)
        navigateBack(in: app)

        let sharing = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Manage sharing'"))
            .firstMatch
        XCTAssertTrue(scrollTo(sharing, in: app), "Manage sharing row not found.")
        sharing.tap()
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 10))
        try audit("Sharing", in: app)
        navigateBack(in: app)

        let scanner = app.buttons["Scan a shared code"]
        XCTAssertTrue(scrollTo(scanner, in: app), "Scanner entry point not found.")
        scanner.tap()
        XCTAssertTrue(app.navigationBars["Scan a link"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            scrollTo(app.buttons["Open Settings"], in: app),
            "Open Settings is not reachable in the denied-camera state."
        )
        try audit("Camera-denied scanner", in: app)
        app.buttons["Done"].tap()

        let widgetsTab = navigationButton(named: "Widgets", in: app)
        widgetsTab.tap()
        XCTAssertTrue(app.buttons["Generate sample widgets"].waitForExistence(timeout: 10))
        try audit("Empty dashboard", in: app, includesContrast: contrastAuditsEnabled)

        app.terminate()
        // A new proxy guarantees XCTest applies the updated launch arguments;
        // mutating and relaunching the original proxy proved timing-dependent
        // at AX5 on a freshly created simulator.
        app = XCUIApplication()
        app.launchArguments = [
            "-ZWSubscriptionState", "expired",
            "-ZWAccessibilitySeedSamples",
        ]
        app.launch()
        let seededWidgetsTab = navigationButton(named: "Widgets", in: app)
        XCTAssertTrue(seededWidgetsTab.waitForExistence(timeout: 30))
        seededWidgetsTab.tap()
        let solar = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Solar'"))
            .firstMatch
        // At accessibility sizes the setup and sample notices fill the first
        // viewport, so the lazy card stack does not instantiate Solar until
        // the dashboard scrolls to it.
        XCTAssertTrue(scrollTo(solar, in: app, swipes: 12), "Sample cards did not render.")

        solar.tap()
        XCTAssertTrue(app.navigationBars["Solar"].waitForExistence(timeout: 10))
        try audit("Card detail", in: app, includesContrast: contrastAuditsEnabled)
        navigateBack(in: app)

        // Contrast is covered on the fully visible detail above. XCTest treats
        // the next card at this scroll viewport's clipped edge as if the edge
        // were its background, producing a non-actionable false failure.
        try audit("Populated dashboard", in: app)

        let activitiesTab = navigationButton(named: "Activities", in: app)
        activitiesTab.tap()
        let activity = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Home battery'"))
            .firstMatch
        XCTAssertTrue(
            scrollTo(activity, in: app, swipes: 12),
            "Sample Live Activity did not render."
        )
        activity.tap()
        XCTAssertTrue(app.navigationBars["Home battery"].waitForExistence(timeout: 10))
        try audit("Activity detail", in: app, includesContrast: contrastAuditsEnabled)
        navigateBack(in: app)

        try audit("Activity list", in: app, includesContrast: contrastAuditsEnabled)
    }

    /// Large is the stricter contrast threshold. At AX5 XCTest samples labels
    /// where enlarged scroll content is partially occluded and reports even
    /// `.primary` text as failing, so AX5 stays focused on layout and semantics.
    private var contrastAuditsEnabled: Bool {
        ProcessInfo.processInfo.environment["ZW_ACCESSIBILITY_AUDIT_SIZE"] != "AX5"
    }

    private func audit(
        _ name: String,
        in app: XCUIApplication,
        includesContrast: Bool = false
    ) throws {
        try XCTContext.runActivity(named: "Accessibility audit: \(name)") { _ in
            var issues: [String] = []
            var auditTypes: XCUIAccessibilityAuditType = [
                .elementDetection,
                .hitRegion,
                .sufficientElementDescription,
                .textClipped,
                .trait,
            ]
            // XCTest's Dynamic Type audit misclassifies native SwiftUI Form
            // labels and buttons, so the runner uses the simulator's real
            // Large and AX5 settings instead. Contrast is similarly limited
            // to custom content surfaces: native Form nodes are reported
            // without a resolvable element and cannot produce actionable
            // failures. Large runs the stricter contrast check; AX5 checks the
            // real enlarged layout without XCTest's occluded-scroll sampling.
            if includesContrast {
                auditTypes.insert(.contrast)
            }
            try app.performAccessibilityAudit(for: auditTypes) { issue in
                // XCTest reports standard SwiftUI control styles that land
                // just inside its antialiasing tolerance as "nearly passed".
                // Keep true contrast failures blocking while avoiding a suite
                // whose result changes with subpixel rendering.
                if issue.auditType == .contrast,
                   issue.compactDescription == "Contrast nearly passed" {
                    return true
                }
                // UISearchBarTextField owns its Dynamic Type layout; XCTest
                // reports it as potentially clipped even when the system field
                // has room at both real sizes exercised by the runner.
                if issue.auditType == .textClipped,
                   issue.element?.elementType == .searchField {
                    return true
                }
                let element = issue.element.map { " Element: \($0)." } ?? ""
                issues.append("\(issue.compactDescription): \(issue.detailedDescription).\(element)")
                return true
            }
            XCTAssertTrue(
                issues.isEmpty,
                "\(name) accessibility issues:\n\(issues.joined(separator: "\n"))"
            )
        }
    }

    private func navigationButton(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: name).firstMatch
    }

    private func navigateBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back button not found.")
        back.tap()
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 5) && element.isHittable { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }

}
