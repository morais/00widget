import Foundation
import SwiftUI
import Testing
@testable import ZeroZeroWidgetTV

/// Whether a grid cell's content stays inside the box the grid gives it.
///
/// The thing to understand before changing any number here is that an
/// over-tall column on this screen has *two* stages, and only the second is a
/// bug. `TVCardMetrics.height` is a constant, so a card whose content wants
/// more is first squeezed: `minimumScaleFactor` shrinks the text until it
/// fits, silently, and the card looks fine at type smaller than it was
/// designed for. Every card on this dashboard is already in that state — the
/// ideal heights run 220-290 points against the 196 a cell offers. Past the
/// point shrinking can absorb, the column simply overflows, and SwiftUI does
/// not clip it: the excess is drawn outside the card's own background, onto
/// the page behind it.
///
/// So the assertion is about ink, not about ideal height. Asserting the ideal
/// fits would fail on a dashboard that has never satisfied it and would say
/// nothing about what a viewer sees; asserting nothing is drawn outside the
/// card is exactly the failure that reached TestFlight.
///
/// Nothing else in the repo can see this. The build cannot, the rest of the
/// suite cannot, and the marketing capture that can is a ten-minute run — it
/// is where this was caught, twice.
@MainActor
@Suite("tvOS card fit")
struct TVCardFitTests {
    private let columns = 3
    private var cardWidth: CGFloat { TVCardMetrics.width(columns: columns) }
    private var contentWidth: CGFloat { TVCardMetrics.contentWidth(columns: columns) }

    /// Room around the card in the test canvas, so an overflow has somewhere
    /// to land where it can be seen.
    private let margin: CGFloat = 80

    /// The cell as the grid draws it, in a canvas taller than itself.
    private func boxedCard(_ card: DashboardCard) -> some View {
        ZStack {
            Color.clear
            TVDashboardCardContent(card: card)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, TVCardMetrics.horizontalPadding)
                .padding(.vertical, TVCardMetrics.verticalPadding)
                .frame(width: cardWidth, height: TVCardMetrics.height)
        }
    }

    @Test("No sample card draws outside the cell it is given")
    func sampleCardsStayInsideTheirBox() {
        for card in SampleDataFactory.makeCards() {
            guard let ink = TVRenderProbe.inkBounds(
                of: boxedCard(card),
                canvas: CGSize(width: cardWidth, height: TVCardMetrics.height + margin * 2)
            ) else {
                Issue.record("\(card.title) drew nothing at all.")
                continue
            }
            let above = margin - ink.minY
            let below = ink.maxY - (margin + TVCardMetrics.height)
            let outside = max(max(above, below), 0)
            #expect(
                outside == 0,
                """
                \(card.title) (\(card.template)) draws outside its card: \
                \(max(above, 0)) points above the top edge, \(max(below, 0)) below \
                the bottom. The excess lands on the page behind the card, \
                because nothing clips it.
                """
            )
        }
    }

    /// The stronger of the two assertions, and the one that keeps the type on
    /// a television the size it was designed to be.
    ///
    /// A card whose content merely *wants* more than the cell offers does not
    /// overflow — `minimumScaleFactor` shrinks the text until it fits, and the
    /// card looks fine at type nobody chose. That was the state of this
    /// dashboard for two releases: ideal heights of 220-306 against a budget
    /// of 196, absorbed silently, with only the worst two cards ever spilling
    /// far enough to be seen. Nothing reported it, because shrinking is what
    /// the modifier is *for*.
    ///
    /// So the bar is that nothing shrinks at all: what each cell draws has to
    /// fit the box unaided. That is a claim about the trimmed card — see
    /// `TVDashboardCardContent.body` for what a cell defers to the panel — and
    /// `TVCardMetrics.height` is derived from the worst of these numbers, so
    /// the two move together. A card that fails this is asking for a row the
    /// cell has not got; take the row away or re-derive the height, and if you
    /// re-derive it check the 304-point two-row ceiling first.
    @Test("No sample card's content has to shrink to fit its cell")
    func sampleCardsFitWithoutShrinking() {
        for card in SampleDataFactory.makeCards() + SampleDataFactory.makeHomeEnergyCards() {
            let ideal = TVRenderProbe.height(
                of: TVDashboardCardContent(card: card),
                width: contentWidth
            )
            #expect(
                ideal <= TVCardMetrics.contentHeight,
                """
                \(card.title) (\(card.template)) wants \(ideal) points of the \
                \(TVCardMetrics.contentHeight) a cell offers, so its text is being \
                shrunk by \(String(format: "%.2f", ideal / TVCardMetrics.contentHeight))x \
                to fit. Nothing looks broken; the type is just smaller than it \
                was designed to be.
                """
            )
        }
    }

    /// A title long enough to still be a name once the row's fixed parts have
    /// taken theirs. About eight characters of `title3`.
    private let titleAllowance: CGFloat = 140

    /// The header is the row that runs out of *horizontal* room, and its
    /// failure is quieter than an overflow: an `HStack` whose children want
    /// more than it has shrinks every flexible one at once rather than
    /// choosing one to yield. A header slightly too wide therefore truncated
    /// the title, the attribution *and* the badge together, and the badge read
    /// "Needs y…" — the one string on the card that had to survive.
    ///
    /// Two separate things have to fit, because the header is not one row: the
    /// title and the attribution are stacked, so the attribution never
    /// competes with the title for width, only with the icon and the badges
    /// beside them.
    @Test("A header's fixed parts leave room for a title")
    func headerChromeLeavesRoomForATitle() {
        for card in SampleDataFactory.makeCards() {
            var bare = card
            bare.title = ""
            bare.producer = nil
            let chrome = TVRenderProbe.width(of: TVDashboardCardContent(card: bare).header)
            #expect(
                chrome + titleAllowance <= contentWidth,
                """
                \(card.title)'s icon and badges want \(chrome) of \(contentWidth) \
                points, leaving \(contentWidth - chrome) for the title.
                """
            )
        }
    }

    @Test("A card's attribution fits beside the icon and badges")
    func attributionFitsItsRow() {
        for card in SampleDataFactory.makeCards() where card.producer != nil {
            var untitled = card
            untitled.title = ""
            let row = TVRenderProbe.width(of: TVDashboardCardContent(card: untitled).header)
            #expect(
                row <= contentWidth,
                "\(card.title)'s attribution row wants \(row) of \(contentWidth) points."
            )
        }
    }
}
