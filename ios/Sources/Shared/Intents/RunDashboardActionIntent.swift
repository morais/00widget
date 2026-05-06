import AppIntents
import Foundation

public struct RunDashboardActionIntent: AppIntent {
    public static var title: LocalizedStringResource = "Run 00Widget action"
    public static var description = IntentDescription("Runs a dashboard action through the 00Widget backend.")

    public static var isDiscoverable = false

    @Parameter(title: "Action ID")
    public var actionId: String

    @Parameter(title: "Card ID")
    public var cardId: String?

    @Parameter(title: "Source")
    public var source: String

    public init() {
        self.actionId = ""
        self.cardId = nil
        self.source = "widget"
    }

    public init(actionId: String, cardId: String? = nil, source: String = "widget") {
        self.actionId = actionId
        self.cardId = cardId
        self.source = source
    }

    public func perform() async throws -> some IntentResult {
        if actionId.isEmpty {
            return .result()
        }

        guard let config = APIClientConfig.fromSettings() else {
            return .result()
        }

        let safe = isActionSafeFromWidget(actionId: actionId, cardId: cardId)
        guard safe else {
            return .result()
        }

        let client = APIClient(config: config)
        do {
            try await client.runAction(id: actionId, cardId: cardId, source: source)
        } catch {
            // Swallow — intents must not throw fatal errors or the system will stop running them.
        }
        return .result()
    }

    private func isActionSafeFromWidget(actionId: String, cardId: String?) -> Bool {
        guard let cardId else { return false }
        guard let card = CardCache.card(withId: cardId),
              let actions = card.actions,
              let action = actions.first(where: { $0.id == actionId })
        else { return false }
        return action.isSafeFromWidget
    }
}
