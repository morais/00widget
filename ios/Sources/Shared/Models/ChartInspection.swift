import Foundation

public struct ChartInspectionValue: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case value
        case series
        case total
        case rangeLow
        case rangeValue
        case rangeHigh
        case reference
    }

    public var id: String
    public var label: String?
    public var value: Double
    public var kind: Kind
    public var semantic: MetricSemantic?

    public init(
        id: String,
        label: String? = nil,
        value: Double,
        kind: Kind,
        semantic: MetricSemantic? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.kind = kind
        self.semantic = semantic
    }
}

public struct ChartInspectionSnapshot: Hashable, Sendable {
    public var index: Int
    public var count: Int
    public var label: String?
    public var signal: MetricSignal?
    public var values: [ChartInspectionValue]
    public var comparison: String?
    public var referenceDifference: Double?
    /// Compact reference result for an interval without a representative
    /// marker. Unlike `referenceDifference`, it describes the whole envelope.
    public var referenceComparison: String?

    public init(
        index: Int,
        count: Int,
        label: String?,
        signal: MetricSignal?,
        values: [ChartInspectionValue],
        comparison: String?,
        referenceDifference: Double?,
        referenceComparison: String? = nil
    ) {
        self.index = index
        self.count = count
        self.label = label
        self.signal = signal
        self.values = values
        self.comparison = comparison
        self.referenceDifference = referenceDifference
        self.referenceComparison = referenceComparison
    }

    public func accessibilityDescription(unit: String?) -> String {
        var parts = [label, "point \(index + 1) of \(count)"].compactMap { $0 }
        if let signal { parts.append(signal.rawValue) }
        parts.append(contentsOf: values.map { value in
            var words = [value.label, Self.format(value.value, unit: unit)].compactMap { $0 }
            words.append(contentsOf: value.semantic?.accessibilityWords ?? [])
            return words.joined(separator: ", ")
        })
        if let comparison { parts.append(comparison) }
        return parts.joined(separator: ". ")
    }

    public static func format(_ value: Double, unit: String?) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        guard let unit, !unit.isEmpty else { return number }
        return "\(number) \(unit)"
    }
}

public extension DashboardChart {
    func inspection(at requestedIndex: Int, unit: String? = nil) -> ChartInspectionSnapshot? {
        guard !points.isEmpty else { return nil }
        let index = Swift.min(Swift.max(requestedIndex, 0), points.count - 1)
        let category = categories.flatMap { $0.indices.contains(index) ? $0[index] : nil }
        let alignedLabel = labels.flatMap { values in
            values.indices.contains(index) ? values[index] : nil
        }
        let label = category?.label ?? alignedLabel

        var values: [ChartInspectionValue] = []
        var comparisonValue: Double?
        var inspectedRange: DashboardChartRange?

        if style == .range,
           let ranges,
           ranges.indices.contains(index) {
            let range = ranges[index]
            inspectedRange = range
            values.append(.init(id: "low", label: "Low", value: range.low, kind: .rangeLow, semantic: semantic))
            if let value = range.value {
                values.append(
                    .init(
                        id: "range-value",
                        label: rangeValueLabel,
                        value: value,
                        kind: .rangeValue,
                        semantic: semantic
                    )
                )
                comparisonValue = value
            }
            values.append(.init(id: "high", label: "High", value: range.high, kind: .rangeHigh, semantic: semantic))
        } else if let series, !series.isEmpty {
            for entry in series where entry.points.indices.contains(index) {
                values.append(
                    .init(
                        id: "series-\(entry.id)",
                        label: entry.label,
                        value: entry.points[index],
                        kind: .series,
                        semantic: resolvedSemantic(for: entry)
                    )
                )
            }
            if values.count > 1 {
                values.append(.init(id: "total", label: "Total", value: points[index], kind: .total, semantic: semantic))
            }
            comparisonValue = points[index]
        } else {
            values.append(.init(id: "value", label: "Value", value: points[index], kind: .value, semantic: semantic))
            comparisonValue = points[index]
        }

        if let reference {
            let referenceLabel = referenceMetadata?.displayLabel ?? "Reference"
            values.append(
                .init(
                    id: "reference",
                    label: referenceLabel,
                    value: reference,
                    kind: .reference,
                    semantic: referenceMetadata?.semantic
                )
            )
        }

        let referenceDifference = comparisonValue.flatMap { value in
            reference.map { value - $0 }
        }
        let intervalComparison = comparisonValue == nil
            ? inspectedRange.flatMap { rangeComparisonDescription(range: $0, unit: unit) }
            : nil
        return ChartInspectionSnapshot(
            index: index,
            count: points.count,
            label: label,
            signal: category?.signal,
            values: values,
            comparison: comparisonValue.flatMap { comparisonDescription(value: $0, unit: unit) }
                ?? intervalComparison?.accessibility,
            referenceDifference: referenceDifference,
            referenceComparison: intervalComparison?.compact
        )
    }

    private func comparisonDescription(value: Double, unit: String?) -> String? {
        guard let reference else { return nil }
        let label = referenceMetadata?.displayLabel ?? "reference"
        let difference = value - reference
        if abs(difference) < 0.000_001 { return "Matches \(label.lowercased())" }
        let amount = ChartInspectionSnapshot.format(abs(difference), unit: unit)
        return "\(amount) \(difference > 0 ? "above" : "below") \(label.lowercased())"
    }

    private func rangeComparisonDescription(
        range: DashboardChartRange,
        unit: String?
    ) -> (compact: String, accessibility: String)? {
        guard let reference else { return nil }
        let label = referenceMetadata?.displayLabel ?? "reference"
        if reference >= range.low, reference <= range.high {
            return ("Within range", "\(label.capitalized) is within range")
        }

        let direction: String
        let near: Double
        let far: Double
        if range.low > reference {
            direction = "above"
            near = range.low - reference
            far = range.high - reference
        } else {
            direction = "below"
            near = reference - range.high
            far = reference - range.low
        }
        let amount = differenceSpan(from: near, to: far, unit: unit)
        return (
            "\(amount) \(direction)",
            "Range is \(amount) \(direction) \(label.lowercased())"
        )
    }

    private func differenceSpan(from near: Double, to far: Double, unit: String?) -> String {
        if abs(near - far) < 0.000_001 {
            return ChartInspectionSnapshot.format(near, unit: unit)
        }
        let first = ChartInspectionSnapshot.format(near, unit: nil)
        let second = ChartInspectionSnapshot.format(far, unit: unit)
        return "\(first)–\(second)"
    }
}
