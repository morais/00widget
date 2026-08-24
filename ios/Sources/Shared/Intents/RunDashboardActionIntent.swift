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
            return finish("Done")
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
