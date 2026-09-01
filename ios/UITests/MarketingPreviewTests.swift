import XCTest

/// Drives only the prepared App Store Preview stage. Widget placement remains
/// a one-time manual task; this test launches the offline fixture mode, moves
/// to the configured first Home Screen page, and executes timed page changes.
final class MarketingPreviewTests: XCTestCase {
    private struct PreviewConfig: Decodable {
        struct Output: Decodable { let duration: Double }
        struct Stage: Decodable { let initialPage: Int }
        struct Scene: Decodable {
            let start: Double
            let action: String
            let label: String?
        }
        struct Fixtures: Codable {
            struct Countdown: Codable { let title: String; let date: String }
            struct Mars: Codable { let distanceKm: Int; let lightMinutes: Double }
            struct Weekend: Codable {
                let title: String
                let status: String
                let temperature: Int
                let wind: Int
            }

            let referenceDate: String?
            let countdown: Countdown
            let mars: Mars
            let weekend: Weekend
        }

        let output: Output
        let stage: Stage
        let scenes: [Scene]
        let fixtures: Fixtures?
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testRunConfiguredPreview() throws {
        let runId = try XCTUnwrap(
            ProcessInfo.processInfo.environment["ZW_APP_PREVIEW_RUN_ID"],
            "The capture host did not provide ZW_APP_PREVIEW_RUN_ID."
        )
        let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents/AppPreview/\(runId)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        XCTAssertTrue(waitForFile(configURL, timeout: 120), "The capture host never supplied config.json.")
        let config = try JSONDecoder().decode(PreviewConfig.self, from: Data(contentsOf: configURL))

        let app = XCUIApplication()
        app.launchArguments = ["--marketing-demo"]
        if let referenceDate = config.fixtures?.referenceDate {
            app.launchArguments += ["--marketing-reference-date", referenceDate]
        }
        if let fixtures = config.fixtures {
            let encoded = try JSONEncoder().encode(fixtures).base64EncodedString()
            app.launchArguments += ["--marketing-fixtures", encoded]
        }
        app.launch()
        let countdownTitle = config.fixtures?.countdown.title ?? "Julia turns 12"
        XCTAssertTrue(
            app.staticTexts[countdownTitle].firstMatch.waitForExistence(timeout: 30),
            "Marketing demo cards did not load; use a ZW_SCREENSHOTS build."
        )
        // Give WidgetCenter's explicit reload time to update the prepared
        // static widgets before they enter the framebuffer recording.
        Thread.sleep(forTimeInterval: 2)

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        // Swiping all the way right lands on the far-left Today/widgets view,
        // which is not an ordinary SpringBoard page. Move left once so
        // `initialPage: 0` means the first normal Home Screen page.
        for _ in 0..<8 { springboard.swipeRight() }
        springboard.swipeLeft()
        if config.stage.initialPage > 0 {
            for _ in 0..<config.stage.initialPage { springboard.swipeLeft() }
        }
        Thread.sleep(forTimeInterval: 1)

        try Data("ready\n".utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic)
        let startURL = directory.appendingPathComponent("start")
        XCTAssertTrue(waitForFile(startURL, timeout: 180), "The capture host never started recording.")

        let baseline = ProcessInfo.processInfo.systemUptime
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        let events = try FileHandle(forWritingTo: eventsURL)
        defer { try? events.close() }

        for scene in config.scenes {
            wait(until: baseline + scene.start)
            let actual = ProcessInfo.processInfo.systemUptime - baseline
            perform(scene.action, app: app, springboard: springboard)
            let completedAt = ProcessInfo.processInfo.systemUptime - baseline
            try appendEvent(
                time: actual,
                completedAt: completedAt,
                label: scene.label ?? scene.action,
                action: scene.action,
                to: events
            )
        }
        wait(until: baseline + config.output.duration)
        try Data("finished\n".utf8).write(
            to: directory.appendingPathComponent("finished"),
            options: .atomic
        )
    }

    private func perform(
        _ action: String,
        app: XCUIApplication,
        springboard: XCUIApplication
    ) {
        switch action {
        case "hold":
            break
        case "go_home":
            XCUIDevice.shared.press(.home)
        case "swipe_left":
            springboard.swipeLeft()
        case "swipe_right":
            springboard.swipeRight()
        case "open_app":
            app.activate()
        default:
            XCTFail("Unsupported preview action: \(action)")
        }
    }

    private func wait(until deadline: TimeInterval) {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            Thread.sleep(forTimeInterval: min(remaining, 0.05))
        }
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func appendEvent(
        time: Double,
        completedAt: Double,
        label: String,
        action: String,
        to handle: FileHandle
    ) throws {
        let payload: [String: Any] = [
            "time": time,
            "completedAt": completedAt,
            "label": label,
            "action": action,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try handle.write(contentsOf: data + Data("\n".utf8))
        try handle.synchronize()
    }
}
