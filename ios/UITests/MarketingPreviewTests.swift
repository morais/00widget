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
            let target: String?
            let phase: String?
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
            let countdown: Countdown?
            let mars: Mars?
            let weekend: Weekend?
        }

        let output: Output
        let stage: Stage
        let scenes: [Scene]
        let fixtures: Fixtures?
        let preview: Preview?

        struct Preview: Decodable { let initialPhase: String? }
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
        // A previous run can leave the app suspended; activating it would
        // resume without launch arguments and miss the demo fixtures.
        // Terminate first so this launch carries its args, and let the old
        // process finish dying before launching.
        app.terminate()
        Thread.sleep(forTimeInterval: 2)
        app.launchArguments = ["--marketing-demo"]
        if let referenceDate = config.fixtures?.referenceDate {
            app.launchArguments += ["--marketing-reference-date", referenceDate]
        }
        if let fixtures = config.fixtures {
            let encoded = try JSONEncoder().encode(fixtures).base64EncodedString()
            app.launchArguments += ["--marketing-fixtures", encoded]
        }
        if let initialPhase = config.preview?.initialPhase {
            app.launchArguments += ["--preview-launch-phase", initialPhase]
        }
        app.launch()
        let demoReady: Bool
        if config.preview?.initialPhase != nil {
            if !app.staticTexts["Launch"].firstMatch.waitForExistence(timeout: 60) {
                print("PREVIEW first launch missed the demo cards; relaunching once")
                app.terminate()
                Thread.sleep(forTimeInterval: 2)
                app.launch()
            }
            demoReady = app.staticTexts["Launch"].firstMatch.waitForExistence(timeout: 60)
            XCTAssertTrue(
                demoReady,
                "Preview launch cards did not load; use a ZW_SCREENSHOTS build."
            )
        } else {
            let countdownTitle = config.fixtures?.countdown?.title ?? "Julia turns 12"
            XCTAssertTrue(
                app.staticTexts[countdownTitle].firstMatch.waitForExistence(timeout: 30),
                "Marketing demo cards did not load; use a ZW_SCREENSHOTS build."
            )
        }
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

        // Scene actions run against the moment recording was observed to
        // start. The host gates the marker on the movie file itself rather
        // than a flushed log line, so the residual offset stays inside the
        // overlays' fade margins.
        let baseline = ProcessInfo.processInfo.systemUptime
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        let events = try FileHandle(forWritingTo: eventsURL)
        defer { try? events.close() }

        for scene in config.scenes {
            wait(until: baseline + scene.start)
            let actual = ProcessInfo.processInfo.systemUptime - baseline
            perform(scene, app: app, springboard: springboard)
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
        _ scene: PreviewConfig.Scene,
        app: XCUIApplication,
        springboard: XCUIApplication
    ) {
        switch scene.action {
        case "hold":
            break
        case "go_home":
            XCUIDevice.shared.press(.home)
        case "swipe_left":
            swipePage(left: true, in: springboard)
        case "swipe_right":
            swipePage(left: false, in: springboard)
        case "open_app":
            app.activate()
        case "tap":
            guard let target = scene.target, !target.isEmpty else {
                XCTFail("Preview action 'tap' needs a 'target' accessibility identifier.")
                return
            }
            tap(accessibilityIdentifier: target, in: app)
        case "preview_phase":
            guard let phase = scene.phase, ["a", "b", "c"].contains(phase) else {
                XCTFail("Preview action 'preview_phase' needs phase 'a', 'b' or 'c'.")
                return
            }
            // A Darwin notification crosses to the app with no entitlements
            // and nothing visible on screen, so the island can change
            // mid-timeline while the recording stays on SpringBoard.
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.00widget.preview.phase.\(phase)" as CFString),
                nil,
                nil,
                true
            )
            // Let ActivityKit apply the ContentState update before the next
            // scene samples the framebuffer.
            Thread.sleep(forTimeInterval: 1.0)
        default:
            XCTFail("Unsupported preview action: \(scene.action)")
        }
    }

    /// Resolves a stable accessibility identifier or label without screen
    /// coordinates. Coordinates would couple the timeline to one device size;
    /// identifiers survive every simulator the capture runs on. An exact
    /// identifier-or-label match wins; a label-substring fallback lets the
    /// timeline name the card ("Launch") instead of pinning the whole
    /// VoiceOver sentence the renderer composes around it.
    private func tap(accessibilityIdentifier id: String, in app: XCUIApplication) {
        let exact = app.descendants(matching: .any)[id]
        if exact.exists {
            exact.tap()
            return
        }
        let fuzzy = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", id)
        ).firstMatch
        XCTAssertTrue(
            fuzzy.waitForExistence(timeout: 10),
            "Preview tap target never appeared: \(id)"
        )
        fuzzy.tap()
    }

    private func swipePage(left: Bool, in springboard: XCUIApplication) {
        // Drive the gesture through the empty strip between the widgets and
        // Search. Starting on a widget briefly highlights its snapshot (and
        // can record as a black flash), while XCUIElement.swipeLeft() also
        // takes about two seconds and makes the page look stuck mid-scroll.
        let startX = left ? 0.90 : 0.10
        let endX = left ? 0.10 : 0.90
        let start = springboard.coordinate(
            withNormalizedOffset: CGVector(dx: startX, dy: 0.78)
        )
        let end = springboard.coordinate(
            withNormalizedOffset: CGVector(dx: endX, dy: 0.78)
        )
        start.press(
            forDuration: 0.01,
            thenDragTo: end,
            withVelocity: 1_200,
            thenHoldForDuration: 0
        )
        // Let SpringBoard finish its animation before forcing a settled sample.
        // Sampling immediately can freeze the animation; never sampling can
        // make CoreSimulator's variable-frame-rate recorder omit the swipe.
        Thread.sleep(forTimeInterval: 0.5)
        _ = XCUIScreen.main.screenshot()
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
