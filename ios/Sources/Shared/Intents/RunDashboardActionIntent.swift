import AppIntents
import Foundation

public struct RunDashboardActionIntent: AppIntent, ProgressReportingIntent {
    public static var title: LocalizedStringResource = "Run 00Widget action"
    public static var description = IntentDescription("Runs a dashboard action through the 00Widget backend.")

    public static var isDiscoverable = false

    @Parameter(title: "Action ID")
    public var actionId: String

    @Parameter(title: "Card ID")
    public var cardId: String?

    public init() {
        self.actionId = ""
        self.cardId = nil
    }

    public init(actionId: String, cardId: String? = nil) {
        self.actionId = actionId
        self.cardId = cardId
    }

    /// Runs the action and reports what happened.
    ///
    /// This used to be fire-and-forget by construction: every failure path
    /// returned a bare `.result()`, so tapping a button on a widget produced no
    /// signal at all — not while it ran, not when it worked, and not when it
    /// silently did nothing. `ProgressReportingIntent` is iOS 17 and needs no
    /// new SDK; conforming turns the tap into "Running…" and then an outcome.
    ///
    /// It still never throws. An intent that throws fatal errors is one the
    /// system stops running, which is why every branch here ends in a
    /// completed progress and `.result()` rather than an error.
    public func perform() async throws -> some IntentResult {
        progress.totalUnitCount = 1
        progress.localizedDescription = "Preparing…"

        if Task.isCancelled {
            return finish("Cancelled")
        }

        guard !actionId.isEmpty else {
            return finish("Nothing to run")
        }

        guard let action = safeAction() else {
            // The gate is unchanged — a destructive action, or one wanting
            // confirmation, still does not run from a widget. What changes is
            // that it no longer looks like a dead button: the person is told
            // where the action lives instead of being left guessing.
            return finish("Open 00Widget to run this")
        }

        guard let config = APIClientConfig.fromSettings() else {
            return finish("Sign in to run this")
        }

        progress.localizedDescription = "Running \(action.label)…"

        do {
            try await APIClient(config: config).runAction(id: actionId, cardId: cardId)
            if Task.isCancelled {
                return finish("Cancelled")
            }
            return finish("Done")
        } catch is CancellationError {
            // A cancelled run is not a failed run: reporting it as
            // "Couldn't run" would send the person retrying something they
            // just asked to stop.
            return finish("Cancelled")
        } catch {
            // Swallowed, as before. Reported now, which is the whole point:
            // "Couldn't run" is a worse outcome than "Done" and a far better
            // one than a button that appears to do nothing.
            return finish("Couldn't run \(action.label)")
        }
    }

    private func finish(_ description: String) -> some IntentResult {
        progress.localizedDescription = description
        progress.completedUnitCount = progress.totalUnitCount
        return .result()
    }

    /// The action this intent may run from a widget, or nil.
    ///
    /// Returns the definition rather than a Bool so the progress text can name
    /// it. The rule itself is untouched: `ActionDefinition.isSafeFromWidget` is
    /// still the only thing consulted, and it is still the enforcement point
    /// for destructive actions never running from a widget.
    private func safeAction() -> ActionDefinition? {
        guard
            let cardId,
            let card = CardCache.card(withId: cardId),
            let action = card.actions?.first(where: { $0.id == actionId }),
            action.isSafeFromWidget
        else {
            return nil
        }
        return action
    }
}

// `LiveActivityIntent` quick actions (spike).
//
// WWDC26 sess. 223: Live Activity buttons can run App Intents conforming to
// `LiveActivityIntent`. Conforming here unblocks one-tap safe actions
// (acknowledge, snooze) from the Lock Screen banner and the expanded island,
// reusing the same server webhook path cards already use — no new SDK, the
// protocol is iOS 17 and present in both the 26.5 and 27.0 SDKs.
//
// The `isSafeFromWidget` rule extends to island buttons unchanged: a
// destructive action, or one wanting confirmation, still does not run from an
// intent — `safeAction()` above remains the only enforcement point, and the
// person is told to open the app instead. Buttons do not act in CarPlay: the
// `.small` activity family (watch, CarPlay Dashboard, menu bar) draws no
// buttons, so there is nothing to gate there.
//
// No buttons are added yet, and no server change: activities carry no
// `actions` today (see `StartLiveActivitySchema`, which has none, unlike
// cards). Decided 2026-09-07: when the UI arrives, island-originated runs
// reuse the existing action path as-is — same scopes, no extra attribution —
// so a run from the island is indistinguishable from one from a widget.
#if os(iOS)
extension RunDashboardActionIntent: LiveActivityIntent {}
#endif

// `CancellableIntent`, and the only place in this target that names it.
//
// Agent runs are cancellable by nature — a multi-minute job started from a
// widget should stop when the person asks it to, not run to completion
// because the intent had no way to hear the cancellation. Conforming lets the
// system cancel the task (timeout, user-cancelled); `perform()` above already
// honours `Task.isCancelled` and reports it as "Cancelled" rather than as a
// failure, so no new SDK is needed for the behaviour, only for the protocol.
//
// The gate is the same shape as `FullPageWidgetFamily` and
// `SpotlightReindexing`, and exists for the second reason AGENTS.md records:
// `CancellableIntent` is annotated `@available(anyAppleOS 26.4, *)` — which
// reads as back-deployable to an OS older than the submission machine — yet is
// absent from the iOS 26.5 SDK entirely (AppIntents 300.5.12 vs 301.0.51.1.102
// in the 27.0 SDK). Naming it there is a compile-time error no `#available`
// can rescue, so the conformance lives behind
// `canImport(AppIntents, _version: 301)`. The runtime `@available` still
// matters because the app deploys back to 26.0.
#if canImport(AppIntents, _version: 301)
@available(iOS 26.4, tvOS 26.4, *)
extension RunDashboardActionIntent: CancellableIntent {}
#endif
