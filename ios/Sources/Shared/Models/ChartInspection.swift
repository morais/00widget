import Foundation

public struct ChartInspectionValue: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case value
        case series
        case total
        case rangeLow
        case rangeCurrent
        case rangeMidpoint
        case rangeHigh
        case reference
    }

    public var id: String
    public var label: String
    public var value: Double
    public var kind: Kind
    public var semantic: MetricSemantic?

    public init(
        id: String,
        label: String,
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

    public init(
        index: Int,
        count: Int,
        label: String?,
        signal: MetricSignal?,
        values: [ChartInspectionValue],
        comparison: String?,
        referenceDifference: Double?
    ) {
        self.index = index
        self.count = count
        self.label = label
        self.signal = signal
        self.values = values
        self.comparison = comparison
        self.referenceDifference = referenceDifference
    }

    public func accessibilityDescription(unit: String?) -> String {
        var parts = [label, "point \(index + 1) of \(count)"].compactMap { $0 }
        if let signal { parts.append(signal.rawValue) }
        parts.append(contentsOf: values.map { value in
            var words = [value.label, Self.format(value.value, unit: unit)]
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

        if style == .range,
           let ranges,
           ranges.indices.contains(index) {
            let range = ranges[index]
            values.append(.init(id: "low", label: "Low", value: range.low, kind: .rangeLow, semantic: semantic))
            if let current = range.value {
                values.append(.init(id: "current", label: "Current", value: current, kind: .rangeCurrent, semantic: semantic))
                comparisonValue = current
            } else {
                let midpoint = (range.low + range.high) / 2
                values.append(.init(id: "midpoint", label: "Midpoint", value: midpoint, kind: .rangeMidpoint, semantic: semantic))
                comparisonValue = midpoint
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
        return ChartInspectionSnapshot(
            index: index,
            count: points.count,
            label: label,
            signal: category?.signal,
            values: values,
            comparison: comparisonValue.flatMap { comparisonDescription(value: $0, unit: unit) },
            referenceDifference: referenceDifference
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
}
