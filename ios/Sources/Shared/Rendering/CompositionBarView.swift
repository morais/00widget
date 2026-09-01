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
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

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
    /// `increasedContrast` raises the steps rather than removing them: the
    /// step *is* the segment's identity when nothing else distinguishes it,
    /// and a fifth segment at 0.22 of the card's tint is the faintest thing
    /// this app draws. Every surface that draws a swatch for a segment passes
    /// the same flag, so a legend and its bar cannot land on different shades.
    public static func tint(
        for item: DashboardItem,
        index: Int,
        base: Color,
        increasedContrast: Bool = false
    ) -> Color {
        if let status = item.status { return status.tint }
        if let semantic = item.semantic {
            return ChartSeriesPalette.tint(index: index, base: base, semantic: semantic)
        }
        return base.opacity(
            VisualAccommodations.fillOpacity(
                Swift.max(0.22, pow(0.72, Double(index))),
                increasedContrast: increasedContrast
            )
        )
    }

    public var body: some View {
        let shares = Self.shares(of: items)
        GeometryReader { proxy in
            let available = proxy.size.width - gap * CGFloat(Swift.max(0, shares.count - 1))
            ZStack(alignment: .leading) {
                ForEach(Array(shares.enumerated()), id: \.element.item.id) { index, entry in
                    let width = Swift.max(2, available * entry.share)
                    // Segments of one quantity, so the colours are steps of a
                    // single tint by design — which leaves adjacent segments
                    // separated by a 2pt gap and a shade, and nothing at all
                    // for someone not reading the shade. The texture is what
                    // the gap alone could not say.
                    RoundedRectangle(cornerRadius: height / 3, style: .continuous)
                        .seriesFill(
                            Self.tint(
                                for: entry.item,
                                index: index,
                                base: tint,
                                increasedContrast: colorSchemeContrast == .increased
                            ),
                            marker: SeriesMarker.at(index),
                            textured: differentiateWithoutColor,
                            spacing: Swift.max(4, height / 3)
                        )
                        .frame(width: width)
                        .offset(x: offset(before: index, shares: shares, available: available))
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text(Self.accessibilityDescription(for: items)))
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

    /// Shared with surfaces that draw the bar inside a single combined element
    /// and therefore cannot inherit its label — see the note on
    /// `StatusStripView.accessibilityDescription(for:)`.
    public static func accessibilityDescription(for items: [DashboardItem]) -> String {
        let shares = Self.shares(of: items)
        guard !shares.isEmpty else { return "No breakdown data" }
        return shares
            .map {
                let meaning = $0.item.semantic?.accessibilityWords.joined(separator: " ") ?? ""
                return ["\($0.item.title) \(Int(($0.share * 100).rounded()))%", meaning]
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            }
            .joined(separator: ", ")
    }
}
