import AppIntents
import Foundation

/// Opens one card's detail screen.
///
/// This is what makes the Spotlight donation lead somewhere. Without it a
/// search hit on a donated card cold-launches the app onto whatever tab it
/// happens to open on: the person searched for the boiler and got the app.
///
/// `OpenIntent` is the conformance the system looks for when it offers to open
/// an entity, and `DashboardCardEntity.urlRepresentation` gives Spotlight the
/// same destination as a URL for the paths that prefer one. Both resolve to
/// `zerozerowidget://card/<id>`, so there is one route to keep working.
struct OpenCardIntent: AppIntent, OpenIntent {
    static var title: LocalizedStringResource = "Open card"
    static var description = IntentDescription("Opens a dashboard card in 00Widget.")

    static var openAppWhenRun = true

    @Parameter(title: "Card", requestValueDialog: "Which card?")
    var target: DashboardCardEntity

    init() {}

    init(target: DashboardCardEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLanding.request(.card(id: target.id))
        return .result()
    }
}
