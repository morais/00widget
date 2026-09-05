import Foundation
import SwiftUI
import Testing
import UIKit
@testable import ZeroZeroWidgetApp

/// What the App Clip draws for a shared Live Activity.
///
/// This is the first thing a stranger sees of the product — someone opened a
/// link, and this is the whole demonstration — so it is worth more than a
/// manual look before release. `GuestActivityPreview` lives in
/// `Sources/Shared` rather than `Sources/Clip` for that reason: a renderer
/// only a clip can reach is one nothing cheap can measure.
///
/// The layout question it answers is height. The preview has no fixed frame,
/// so it cannot overflow the way a tvOS cell does; what it can do is grow past
/// the screen of the phone it is being read on, which on the narrowest one
/// leaves the call to action below the fold on the only screen the clip has.
@MainActor
@Suite("Guest activity preview")
struct GuestActivityPreviewTests {
    /// The content width on the narrowest iPhone: 320 points less the root
    /// view's 24-point padding on each side.
    private let narrowContentWidth: CGFloat = 272

    private func height(of view: some View, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        host.view.layoutIfNeeded()
        return host.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
    }

    @Test("The preview fits the smallest phone with room for the button")
    func fitsTheNarrowestPhone() {
        let session = SampleDataFactory.makeLiveActivitySession()
        let measured = height(
            of: GuestActivityPreview(session: session),
            width: narrowContentWidth
        )

        // A 4.7-inch phone is 568 points tall. The clip spends roughly 180 on
        // its own chrome — status bar, the confirmation line, the read-only
        // note, and the pinned call to action — so the preview has about 380.
        #expect(measured > 0)
        #expect(
            measured <= 380,
            """
            The guest preview wants \(measured)pt on the narrowest iPhone, \
            which pushes the "Keep following" button off the only screen an \
            App Clip gets. Give a row up rather than growing the card.
            """
        )
    }

    @Test("It shows the rows the shared budget allows, not every item")
    func showsBudgetedRows() {
        let session = SampleDataFactory.makeLiveActivitySession()
        // Five items in the sample, one of them active. The clip shows three:
        // the same rule every other surface follows, so a shared link cannot
        // quietly reveal more of a run than the sender's own screens do.
        #expect(session.items?.count == 5)
        #expect(
            session.budgetedPresentationItems(fillingTo: 3).map(\.id)
                == ["announcement", "store", "website"]
        )
    }
}
