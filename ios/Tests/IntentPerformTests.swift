import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// Intent perform-path tests that need no UI automation and no Siri runtime.
///
/// iOS 27's App Intents Testing framework validates Siri/Shortcuts/Spotlight
/// through real system pathways; the framework itself is not in this SDK
/// snapshot as an importable module, so these use Swift Testing directly
/// against the same seam — the pure `perform()` paths — which is the half of
/// that promise that matters here given the "Simulator doesn't rehydrate
/// AppIntents" pain: intent logic must be exercisable without the system
/// resolving anything first.
@Suite("Intent perform paths")
struct IntentPerformTests {

    @Test("Search intent performs without throwing")
    @MainActor
    func searchIntentPerforms() async throws {
        let intent = SearchCardsIntent(term: "boiler")
        _ = try await intent.perform()
    }

    @Test("An action intent with nothing to run finishes without throwing")
    func emptyActionIntentFinishes() async throws {
        let intent = RunDashboardActionIntent(actionId: "")
        _ = try await intent.perform()
    }

    @Test("An action intent for an unknown card finishes without throwing")
    func unknownCardActionFinishes() async throws {
        let intent = RunDashboardActionIntent(
            actionId: "approve",
            cardId: "definitely-not-in-the-cache-\(UUID().uuidString)"
        )
        _ = try await intent.perform()
    }
}
