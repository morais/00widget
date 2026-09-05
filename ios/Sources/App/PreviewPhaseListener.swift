#if ZW_SCREENSHOTS
import Foundation
import UIKit

/// Advances the screenshot-only preview Live Activity when the preview
/// driver posts a phase.
///
/// A Darwin notification crosses from the UI-test runner to the app with no
/// entitlements and nothing visible on screen, which a relaunch or deep link
/// cannot do mid-timeline: either one would put the app on screen and into
/// the recording. The names carry the phase because the center posts no
/// payload.
///
/// The timeline films SpringBoard, so this app sits backgrounded when the
/// update lands. Without the background task it suspends and the filmed
/// change never happens; the task is renewed on every foregrounding, and
/// the whole listener exists only in screenshot builds.
final class PreviewPhaseListener {
    static let shared = PreviewPhaseListener()

    private var started = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func start(initialPhase: SampleDataFactory.PreviewLaunchPhase) {
        guard !started else { return }
        started = true
        beginBackgroundTask()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for phase in SampleDataFactory.PreviewLaunchPhase.allCases {
            let name = "com.00widget.preview.phase.\(phase.rawValue)" as CFString
            CFNotificationCenterAddObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                previewPhaseChanged,
                name,
                nil,
                .deliverImmediately
            )
        }
        Task { await advance(to: initialPhase) }
    }

    /// Call when the app foregrounds so the task lost to expiry or to the
    /// system is replaced before the next backgrounded beat.
    func noteForegrounded() {
        guard started, backgroundTask == .invalid else { return }
        beginBackgroundTask()
    }

    private func beginBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "preview-phases") { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }

    fileprivate func advance(to phase: SampleDataFactory.PreviewLaunchPhase) async {
        await LiveActivityController.shared.startOrUpdatePreviewSample(phase: phase)
    }
}

private func previewPhaseChanged(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard
        let raw = name?.rawValue as String?,
        let suffix = raw.split(separator: ".").last.map(String.init),
        let phase = SampleDataFactory.PreviewLaunchPhase(rawValue: suffix)
    else { return }
    Task { await PreviewPhaseListener.shared.advance(to: phase) }
}
#endif
