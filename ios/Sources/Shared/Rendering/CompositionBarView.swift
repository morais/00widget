import SwiftUI

/// The `breakdown` template's plot: one bar split into proportional segments.
///
/// Deliberately not a pie. A pie needs a legend to mean anything, and a legend
/// does not fit a small widget — a bar keeps its proportions readable at any
/// width and degrades to a single stripe on the Lock Screen.
public struct CompositionBarView: View {
    public let items: [DashboardItem]
    public let tint: Color
    public let height: CGFloat

    private let gap: CGFloat = 2

    public init(items: [DashboardItem], tint: Color, height: CGFloat = 14) {
        self.items = items
        self.tint = tint
        self.height = height
    }

    /// Negative amounts are treated as zero: a share of a whole cannot be
    /// negative, and dropping the row entirely would silently change the total
    /// every other segment is measured against.
    public static func shares(of items: [DashboardItem]) -> [(item: DashboardItem, share: Double)] {
        let amounts = items.map { Swift.max(0, $0.amount ?? 0) }
        let total = amounts.reduce(0, +)
        guard total > 0 else { return [] }
        return zip(items, amounts).map { ($0, $1 / total) }
    }

    /// Colors follow the card's tint, stepping down in opacity, so a breakdown
    /// reads as one quantity split up rather than as unrelated categories. An
    /// item that sets its own `status` overrides its step — that is how a
    /// publisher marks the slice that is the problem.
    public static func tint(for item: DashboardItem, index: Int, base: Color) -> Color {
        if let status = item.status { return status.tint }
        return base.opacity(Swift.max(0.22, pow(0.72, Double(index))))
    }

    public var body: some View {
        let shares = Self.shares(of: items)
        GeometryReader { proxy in
            let available = proxy.size.width - gap * CGFloat(Swift.max(0, shares.count - 1))
            ZStack(alignment: .leading) {
                ForEach(Array(shares.enumerated()), id: \.element.item.id) { index, entry in
                    let width = Swift.max(2, available * entry.share)
                    RoundedRectangle(cornerRadius: height / 3, style: .continuous)
                        .fill(Self.tint(for: entry.item, index: index, base: tint))
                        .frame(width: width)
                        .offset(x: offset(before: index, shares: shares, available: available))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityDescription(shares)))
    }

    private func offset(
        before index: Int,
        shares: [(item: DashboardItem, share: Double)],
        available: CGFloat
    ) -> CGFloat {
        let preceding = shares.prefix(index).reduce(CGFloat(0)) { total, entry in
            total + Swift.max(2, available * entry.share)
        }
        return preceding + gap * CGFloat(index)
    }

    private func accessibilityDescription(
        _ shares: [(item: DashboardItem, share: Double)]
    ) -> String {
        guard !shares.isEmpty else { return "No breakdown data" }
        return shares
            .map { "\($0.item.title) \(Int(($0.share * 100).rounded()))%" }
            .joined(separator: ", ")
    }
}
