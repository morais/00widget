import Testing
@testable import ZeroZeroWidgetApp

/// What a Lock Screen accessory may draw, and what it must not.
///
/// The circular accessory is a ring about 58 points across. Drawing that ring
/// from `progressValue ?? 0` means a card with no fraction — a count, a
/// status, a currency total — gets an *empty* ring around a real number, which
/// reads as nought per cent of something rather than as a number with no
/// fraction to show.
///
/// This product had already reasoned that out once, in the other place it
/// draws a ring: `minimalProgress` returns `nil` rather than zero for the
/// Dynamic Island's minimal circle, because "a ring stuck at zero says
/// 'nothing has happened' about an activity that may be halfway through,
/// which is worse than no ring". The guard never reached this renderer, so it
/// reached users — anyone who picked such a card for a circular Lock Screen
/// widget saw it.
@Suite("Accessory rendering")
struct AccessoryRenderingTests {
    private func card(_ suffix: String) throws -> DashboardCard {
        try #require(
            SampleDataFactory.makeCards()
                .first { $0.id == SampleDataFactory.sampleId(suffix) }
        )
    }

    /// Which of the deck's cards can honestly wear a ring, and which cannot.
    /// This is also the choice behind which belong in the Lock Screen's
    /// circular slots.
    @Test("Only a card with a fraction can draw a gauge")
    func onlyFractionsGauge() throws {
        // An explicit progress, on any template.
        #expect(try card("launch").progressValue == 0.8)
        #expect(try card("ai-spend").progressValue == 0.613)

        // A chart earns one too, and it is not a fudge: `progressValue` puts
        // the *latest point* in the series' own range, which is the only
        // needle position that means anything where there is no room to plot.
        // Trials' 128 against a 108-130 window is a ring nine tenths round.
        let trials = try #require(try card("trials").progressValue)
        #expect(abs(trials - 20.0 / 22.0) < 0.001)

        // These four have a number and no fraction behind it. Before the fix
        // each drew an empty ring around that number.
        for suffix in ["production", "support", "agent-runs", "open-prs"] {
            #expect(
                try card(suffix).progressValue == nil,
                "\(suffix) has no fraction, so a circular accessory must not ring for it"
            )
        }
    }
}
