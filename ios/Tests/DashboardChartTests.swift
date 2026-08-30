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
    @Test("Inspection exposes every series, total, category signal, and reference comparison")
    func inspectionDescribesMultiSeriesPoint() throws {
        let chart = DashboardChart(
            points: [],
            reference: 12,
            referenceMetadata: DashboardChartReferenceMetadata(
                label: "Budget",
                semantic: MetricSemantic(role: .target)
            ),
            semantic: MetricSemantic(role: .actual),
            style: .bar,
            categories: [
                DashboardChartCategory(id: "mon", label: "Mon", signal: .favorable),
                DashboardChartCategory(id: "tue", label: "Tue", signal: .caution),
            ],
            series: [
                DashboardChartSeries(
                    id: "solar",
                    label: "Solar",
                    points: [8, 10],
                    semantic: MetricSemantic(flow: .inbound)
                ),
                DashboardChartSeries(
                    id: "grid",
                    label: "Grid",
                    points: [6, 5],
                    semantic: MetricSemantic(flow: .outbound)
                ),
            ]
        )

        let snapshot = try #require(chart.inspection(at: 1, unit: "kWh"))
        #expect(snapshot.label == "Tue")
        #expect(snapshot.signal == .caution)
        #expect(snapshot.values.map(\.label) == ["Solar", "Grid", "Total", "Budget"])
        #expect(snapshot.values.map(\.value) == [10, 5, 15, 12])
        #expect(snapshot.values[0].semantic == MetricSemantic(role: .actual, flow: .inbound))
        #expect(snapshot.comparison == "3 kWh above budget")
        #expect(snapshot.accessibilityDescription(unit: "kWh").contains("point 2 of 2"))
    }

    @Test("Range inspection distinguishes a measured value from a derived midpoint")
    func inspectionDescribesRangesHonestly() throws {
        let chart = DashboardChart(
            points: [],
            style: .range,
            labels: ["Now", "+10"],
            ranges: [
                DashboardChartRange(low: 10, high: 20, value: 14),
                DashboardChartRange(low: 12, high: 24),
            ]
        )

        let measured = try #require(chart.inspection(at: 0))
        #expect(measured.values.map(\.label) == ["Low", "Current", "High"])
        #expect(measured.values.map(\.value) == [10, 14, 20])

        let derived = try #require(chart.inspection(at: 1))
        #expect(derived.values.map(\.label) == ["Low", "Midpoint", "High"])
        #expect(derived.values.map(\.value) == [12, 18, 24])
    }

    @Test("Inspection clamps external selections to the published window")
    func inspectionClampsIndex() throws {
        let chart = DashboardChart(points: [4, 7], labels: ["First", "Last"])
        #expect(try #require(chart.inspection(at: -20)).label == "First")
        #expect(try #require(chart.inspection(at: 20)).label == "Last")
    }

    @Test("Rich categories derive labels and unknown future semantics are ignored")
    func categoriesDeriveLabelsAndUnknownSemanticsAreIgnored() throws {
        let json = #"{"points":[1,2],"categories":[{"id":"off","label":"00","signal":"favorable"},{"id":"peak","label":"18","signal":"future-signal"}],"series":[{"id":"charge","label":"Charging","points":[1,2],"semantic":{"role":"actual","flow":"inbound","signal":"favorable"}},{"id":"reserve","label":"Reserve","points":[0,0],"semantic":{"role":"future-role","flow":"future-flow"}}],"style":"bar"}"#
        let chart = try JSONDecoder().decode(DashboardChart.self, from: Data(json.utf8))

        #expect(chart.labels == ["00", "18"])
        #expect(chart.categories?.map(\.signal) == [.favorable, nil])
        #expect(chart.series?[0].semantic == MetricSemantic(
            role: .actual,
            flow: .inbound,
            signal: .favorable
        ))
        #expect(chart.series?[1].semantic == MetricSemantic())
    }

    @Test("Chart semantics describe simple metrics and supply series defaults")
    func chartSemanticsApplyToSimpleAndMultiSeriesCharts() throws {
        let json = #"{"points":[3,5],"semantic":{"role":"forecast","signal":"caution"},"series":[{"id":"in","label":"Import","points":[2,3],"semantic":{"flow":"inbound"}},{"id":"out","label":"Export","points":[1,2],"semantic":{"signal":"favorable"}}],"style":"bar"}"#
        let chart = try JSONDecoder().decode(DashboardChart.self, from: Data(json.utf8))
        let series = try #require(chart.series)

        #expect(chart.semantic == MetricSemantic(role: .forecast, signal: .caution))
        #expect(chart.resolvedSemantic(for: series[0]) == MetricSemantic(
            role: .forecast,
            flow: .inbound,
            signal: .caution
        ))
        #expect(chart.resolvedSemantic(for: series[1]) == MetricSemantic(
            role: .forecast,
            signal: .favorable
        ))
        #expect(chart.accessibilityDescription.contains("forecast"))
    }

    @Test("Reference metadata names and describes the legacy numeric rule")
    func referenceMetadataDescribesLegacyRule() throws {
        let json = #"{"points":[4,7],"reference":6,"referenceMetadata":{"label":"Budget","semantic":{"role":"target","signal":"caution"}}}"#
        let chart = try JSONDecoder().decode(DashboardChart.self, from: Data(json.utf8))

        #expect(chart.reference == 6)
        #expect(chart.referenceMetadata == DashboardChartReferenceMetadata(
            label: "Budget",
            semantic: MetricSemantic(role: .target, signal: .caution)
        ))
        #expect(chart.accessibilityDescription.contains("against a budget of 6"))
        #expect(chart.accessibilityDescription.contains("target, caution"))
    }

    @Test("Downsampling keeps category labels and preserves the strongest signal")
    func downsamplingKeepsCategoryMeaning() throws {
        let chart = DashboardChart(
            points: [1, 2, 3, 4],
            style: .bar,
            categories: [
                DashboardChartCategory(id: "a", label: "A", signal: .favorable),
                DashboardChartCategory(id: "b", label: "B", signal: .caution),
                DashboardChartCategory(id: "c", label: "C", signal: .neutral),
                DashboardChartCategory(id: "d", label: "D", signal: .unfavorable),
            ]
        )
        let reduced = chart.downsampled(toAtMost: 2)

        #expect(reduced.labels == ["B", "D"])
        #expect(reduced.categories == [
            DashboardChartCategory(id: "b", label: "B", signal: .caution),
            DashboardChartCategory(id: "d", label: "D", signal: .unfavorable),
        ])
    }

    @Test("Range-only JSON derives representative fallback points")
    func rangeOnlyJSONDerivesFallbackPoints() throws {
        let json = #"{"ranges":[{"low":10,"high":20,"value":14},{"low":12,"high":24}],"labels":["Mon","Tue"],"style":"range"}"#
        let chart = try JSONDecoder().decode(DashboardChart.self, from: Data(json.utf8))

        #expect(chart.points == [14, 18])
        #expect(chart.ranges?.count == 2)
        #expect(chart.style == .range)
        #expect(chart.normalizedPoints == [0.2857142857142857, 0.5714285714285714])
    }

    @Test("Downsampling range bands preserves their full envelope")
    func downsamplingRangeBandsPreservesEnvelope() throws {
        let chart = DashboardChart(
            points: [],
            style: .range,
            labels: ["A", "B", "C", "D"],
            ranges: [
                DashboardChartRange(low: 10, high: 20, value: 15),
                DashboardChartRange(low: 12, high: 22),
                DashboardChartRange(low: 20, high: 30),
                DashboardChartRange(low: 22, high: 35),
            ]
        )
        let reduced = chart.downsampled(toAtMost: 2)

        #expect(reduced.ranges == [
            DashboardChartRange(low: 10, high: 22, value: 15),
            DashboardChartRange(low: 20, high: 35),
        ])
        #expect(reduced.points == [15, 27.5])
        #expect(reduced.labels == ["B", "D"])
    }

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
