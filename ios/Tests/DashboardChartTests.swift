import Foundation
import Testing
@testable import ZeroZeroWidgetApp

/// The server accepts up to `DashboardChart.publishedPointLimit` points, which
/// the wide surfaces draw in full and the narrow ones cannot. `downsampled`
/// is what the narrow ones use, and it is the only place a plotted value is
/// not something a producer sent — so what it may and may not change is worth
/// pinning down.
@Suite("Dashboard chart downsampling")
struct DashboardChartTests {
    @Test("Series-only JSON derives the totals older clients receive")
    func seriesOnlyJSONDerivesTotals() throws {
        let json = #"{"series":[{"id":"solar","label":"Solar","points":[8,10,7]},{"id":"grid","label":"Grid","points":[6,5,9]}],"labels":["Mon","Tue","Wed"],"style":"bar","stacking":"grouped"}"#
        let chart = try JSONDecoder().decode(DashboardChart.self, from: Data(json.utf8))

        #expect(chart.points == [14, 15, 16])
        #expect(chart.labels == ["Mon", "Tue", "Wed"])
        #expect(chart.series?.map(\.label) == ["Solar", "Grid"])
        #expect(chart.stacking == .grouped)
    }

    @Test("Downsampling keeps labels and every series aligned")
    func downsamplingKeepsSeriesAligned() throws {
        let chart = DashboardChart(
            points: [11, 22, 33, 44],
            style: .bar,
            labels: ["A", "B", "C", "D"],
            series: [
                DashboardChartSeries(id: "one", label: "One", points: [1, 2, 3, 4]),
                DashboardChartSeries(id: "two", label: "Two", points: [10, 20, 30, 40]),
            ]
        )
        let reduced = chart.downsampled(toAtMost: 2)

        #expect(reduced.points == [16.5, 38.5])
        #expect(reduced.series?[0].points == [1.5, 3.5])
        #expect(reduced.series?[1].points == [15, 35])
        #expect(reduced.labels == ["B", "D"])
    }


    @Test("A series that already fits comes back untouched")
    func shortSeriesUnchanged() {
        let chart = DashboardChart(points: [1, 2, 3, 4])
        #expect(chart.downsampled(toAtMost: 24).points == [1, 2, 3, 4])
        #expect(chart.downsampled(toAtMost: 4).points == [1, 2, 3, 4])
    }

    @Test("A cap below two points is not a plot, so the series is left alone")
    func degenerateCapIsIgnored() {
        let chart = DashboardChart(points: Array(repeating: 1, count: 60))
        #expect(chart.downsampled(toAtMost: 1).points.count == 60)
        #expect(chart.downsampled(toAtMost: 0).points.count == 60)
    }

    @Test("The published maximum reduces to exactly each surface's cap")
    func reducesToCap() {
        let chart = DashboardChart(points: (0..<60).map(Double.init))
        for cap in [32, 24, 16] {
            #expect(chart.downsampled(toAtMost: cap).points.count == cap)
        }
    }

    /// The buckets have to tile the series: every input counted once, none
    /// dropped and none double-counted. A ramp makes that checkable, because
    /// the mean of a contiguous run of it is the midpoint of that run.
    @Test("Buckets tile the whole window when the count divides evenly")
    func evenBucketsTileTheWindow() {
        let chart = DashboardChart(points: (0..<60).map(Double.init))
        let reduced = chart.downsampled(toAtMost: 20).points
        // 20 buckets of 3: [0,1,2] -> 1, [3,4,5] -> 4, ... [57,58,59] -> 58.
        let expected: [Double] = (0..<20).map { Double($0 * 3 + 1) }
        #expect(reduced == expected)
    }

    @Test("An uneven count spreads the remainder instead of piling it up")
    func unevenBucketsSpreadTheRemainder() {
        // 60 into 16 is 3.75 per bucket: sizes must be 3s and 4s, never a
        // short first bucket paying for a 15-point last one.
        let points = (0..<60).map(Double.init)
        let reduced = DashboardChart(points: points).downsampled(toAtMost: 16).points
        #expect(reduced.count == 16)
        // Each bucket mean is the midpoint of its run, so consecutive means
        // step by 3 or 4 and the whole span is covered end to end.
        let steps: [Double] = zip(reduced, reduced.dropFirst()).map { $1 - $0 }
        let stepsInRange = steps.allSatisfy { $0 >= 3 && $0 <= 4 }
        #expect(stepsInRange)
        let first: Double = reduced.first ?? .nan
        let last: Double = reduced.last ?? .nan
        #expect(first < 2)
        #expect(last > 57)
    }

    /// The doc comment claims a pinned axis still contains everything it did
    /// before, which holds only because a mean sits between its inputs.
    @Test("No bucket mean escapes the range of the series it came from")
    func meansStayInRange() {
        var generator = SystemRandomNumberGenerator()
        let points = (0..<60).map { _ in Double.random(in: -500...500, using: &generator) }
        let reduced = DashboardChart(points: points).downsampled(toAtMost: 24).points
        let lower: Double = points.min() ?? .nan
        let upper: Double = points.max() ?? .nan
        let withinRange = reduced.allSatisfy { $0 >= lower && $0 <= upper }
        #expect(withinRange)
    }

    @Test("A rising series still rises, which is the whole point of the plot")
    func directionSurvives() {
        let chart = DashboardChart(points: (0..<60).map { Double($0) * 1.5 })
        let reduced = chart.downsampled(toAtMost: 24).points
        let strictlyRising = zip(reduced, reduced.dropFirst()).allSatisfy { $1 > $0 }
        #expect(strictlyRising)
    }

    /// Averaging understates a spike — that is the accepted cost — but it must
    /// not erase one into the surrounding level.
    @Test("A spike is attenuated, not flattened away")
    func spikeSurvivesAttenuated() {
        var points = Array(repeating: 10.0, count: 60)
        points[30] = 110
        let reduced = DashboardChart(points: points).downsampled(toAtMost: 24).points
        let peak: Double = reduced.max() ?? .nan
        #expect(peak > 10)          // still visibly a spike
        #expect(peak < 110)         // and honestly smaller than the raw reading
    }

    @Test("Axis pinning, the reference rule and the style all carry over")
    func presentationCarriesOver() {
        let chart = DashboardChart(
            points: (0..<60).map(Double.init),
            min: -5,
            max: 100,
            reference: 42,
            style: .delta
        )
        let reduced = chart.downsampled(toAtMost: 24)
        #expect(reduced.min == -5)
        #expect(reduced.max == 100)
        #expect(reduced.reference == 42)
        #expect(reduced.style == .delta)
    }
}
