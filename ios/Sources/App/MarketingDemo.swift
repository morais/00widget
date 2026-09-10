import Foundation

/// Launch-argument gate for the offline App Store Preview build.
///
/// The mode only exists in the private screenshot configuration. A shipping
/// build can receive the same argument without changing its data or network
/// behavior.
enum MarketingDemo {
    static var isEnabled: Bool {
        #if ZW_SCREENSHOTS
        ProcessInfo.processInfo.arguments.contains("--marketing-demo")
        #else
        false
        #endif
    }

    static var referenceDate: Date {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let flag = arguments.firstIndex(of: "--marketing-reference-date"),
            arguments.indices.contains(flag + 1),
            let parsed = ZeroZeroWidgetDateFormat.parse(arguments[flag + 1])
        else {
            return ZeroZeroWidgetDateFormat.parse("2026-09-01T09:41:00Z")!
        }
        return parsed
    }

    static var fixtures: MarketingPreviewFixtures {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let flag = arguments.firstIndex(of: "--marketing-fixtures"),
            arguments.indices.contains(flag + 1),
            let data = Data(base64Encoded: arguments[flag + 1]),
            let decoded = try? JSONDecoder().decode(MarketingPreviewFixtures.self, from: data)
        else {
            return .previewDefault
        }
        return decoded
    }

    /// The preview timeline films the launch story instead of the legacy
    /// countdown/Mars/weekend fixtures. Present only when the capture host
    /// passes `--preview-launch-phase`; the old yaml path keeps working
    /// until it is rewritten.
    static var usesPreviewLaunchStory: Bool {
        #if ZW_SCREENSHOTS
        ProcessInfo.processInfo.arguments.contains("--preview-launch-phase")
        #else
        false
        #endif
    }

    static var initialPreviewPhase: SampleDataFactory.PreviewLaunchPhase {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let flag = arguments.firstIndex(of: "--preview-launch-phase"),
            arguments.indices.contains(flag + 1),
            let phase = SampleDataFactory.PreviewLaunchPhase(rawValue: arguments[flag + 1])
        else {
            return .a
        }
        return phase
    }

    #if ZW_SCREENSHOTS
    /// Selects one compact Dynamic Island branch for the private screenshot
    /// harness. A shipping build never compiles this fixture path.
    static var compactActivityPreview: SampleDataFactory.CompactActivityPreview? {
        let arguments = ProcessInfo.processInfo.arguments
        guard
            let flag = arguments.firstIndex(of: "--compact-activity-preview"),
            arguments.indices.contains(flag + 1)
        else { return nil }
        return SampleDataFactory.CompactActivityPreview(rawValue: arguments[flag + 1])
    }
    #endif
}
