import AppIntents
import Foundation

/// Siri and Shortcuts entry points for the two questions a person actually
/// asks this app: *show me my dashboard* and *what is X doing right now*.
///
/// Both run on iOS 26 with no new SDK. The card shortcut deliberately reads
/// `CardCache` rather than answering from the `DashboardCardEntity` Siri
/// resolved — an entity is a snapshot taken whenever the index was last
/// donated, and a spoken number that is quietly an hour old is the same
/// failure the Dynamic Island's clipped-value bug was: wrong, and indistinguishable
/// from right.
///
/// What may be answered is `SpotlightIndex.indexable`, not the whole cache.
/// Siri answering out loud is the same disclosure as Spotlight answering in a
/// search field, so it inherits the same policy: no samples, nothing belonging
/// to another tenant.
struct ZeroZeroWidgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowDashboardIntent(),
            phrases: [
                "Show my \(.applicationName) dashboard",
                "Open my \(.applicationName) dashboard",
                "Show my dashboard in \(.applicationName)"
            ],
            shortTitle: "Show dashboard",
            systemImageName: "square.grid.2x2"
        )

        AppShortcut(
            intent: CardStatusIntent(),
            phrases: [
                "What's the status of \(\.$card) in \(.applicationName)",
                "What's my \(\.$card) status in \(.applicationName)",
                "Check \(\.$card) in \(.applicationName)"
            ],
            shortTitle: "Card status",
            systemImageName: "info.circle",
            parameterPresentation: ParameterPresentation(
                for: \.$card,
                summary: Summary("Get the status of \(\.$card)"),
                optionsCollections: {
                    OptionsCollection(
                        DashboardCardEntityQuery(),
                        title: "Cards",
                        systemImageName: "square.grid.2x2"
                    )
                }
            )
        )
    }
}

// MARK: - Show my dashboard

struct ShowDashboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Show dashboard"
    static var description = IntentDescription("Opens 00Widget on the dashboard.")

    static var openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // Naming the destination rather than trusting the launch default:
        // RootView opens on Settings for anyone with no API key and no guest
        // links, which is the one case where "show my dashboard" would show
        // anything but.
        IntentLanding.request(.dashboard)
        return .result()
    }
}

// MARK: - What's the status of <card>

struct CardStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get card status"
    static var description = IntentDescription("Reports the latest state an agent published to a dashboard card.")

    /// The answer is the whole point, so this one stays out of the app. A
    /// spoken reply that also yanks the person into a full-screen app is worse
    /// than no reply at all when they asked from a car or a watch.
    static var openAppWhenRun = false

    @Parameter(title: "Card", requestValueDialog: "Which card?")
    var card: DashboardCardEntity

    init() {}

    init(card: DashboardCardEntity) {
        self.card = card
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = CardStatusReport.answer(forCardWithId: card.id, fallbackTitle: card.title)
        return .result(value: answer, dialog: IntentDialog("\(answer)"))
    }
}

/// Turns a card into one spoken sentence-run. Pure and separate from the intent
/// so the wording is testable without the AppIntents runtime.
enum CardStatusReport {
    /// Re-reads the card by id and describes it, or says plainly that it has
    /// gone. A card can disappear between Siri resolving the entity and the
    /// intent running — a `replacePrefix` batch upsert shrinks a namespace, a
    /// producer deletes, somebody signs out — and inventing a last-known value
    /// for it would be the one answer worse than "it's gone".
    static func answer(forCardWithId id: String, fallbackTitle: String, now: Date = Date()) -> String {
        guard let card = SpotlightIndex.indexable(CardCache.load().cards).first(where: { $0.id == id }) else {
            return "\(fallbackTitle) is no longer published."
        }
        return summary(for: card, now: now)
    }

    /// Ordering is what someone asking out loud wants first: the number if the
    /// card publishes one, otherwise the status word — and the status word as
    /// well when both exist, because a solar card reading "3.4 kW" while its
    /// status is `critical` has to say both or it misleads.
    static func summary(for card: DashboardCard, now: Date = Date()) -> String {
        CardAccessibilitySummary.summary(for: card, now: now)
    }
}

// MARK: - Landing

/// Where an intent asks the app to land.
///
/// Not written straight onto `AppEnvironment.requestedLandingTab`, because on a
/// cold launch the system performs the intent while SwiftUI is still building
/// the scene and there is no environment yet. The request parks here and
/// `AppEnvironment` collects it on attach; `RootView` already reacts to
/// `requestedLandingTab` changing, so a warm launch needs nothing extra.
@MainActor
enum IntentLanding {
    /// The dashboard as a whole, or one card on it. `.dashboard` is not a
    /// `ZeroZeroWidgetInternalLink.Destination` because no URL points at it —
    /// "show my dashboard" is a request to be somewhere, not to open a thing.
    enum Request: Equatable {
        case dashboard
        case card(id: String)
        case search(term: String)
    }

    private static var pending: Request?
    private static weak var environment: AppEnvironment?

    static func attach(_ env: AppEnvironment) {
        environment = env
        if let request = pending {
            pending = nil
            apply(request, to: env)
        }
    }

    static func request(_ request: Request) {
        if let environment {
            apply(request, to: environment)
        } else {
            pending = request
        }
    }

    private static func apply(_ request: Request, to env: AppEnvironment) {
        switch request {
        case .dashboard:
            env.requestedCardId = nil
            env.requestedLandingTab = "widgets"
        case .card(let id):
            env.go(to: .card(id: id))
        case .search(let term):
            env.requestedSearchQuery = term
            env.requestedLandingTab = "widgets"
        }
    }
}
