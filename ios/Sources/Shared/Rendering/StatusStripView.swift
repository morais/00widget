import SwiftUI

/// The `history` template's plot: one pip per item, oldest on the left.
///
/// A `chart` needs numbers. A run of outcomes — builds, backups, uptime checks,
/// doses taken — has none, and flattening pass/fail into 1/0 draws a plot that
/// reads as a trend when it is really a tally. Pips keep the reading honest and
/// stay legible far smaller than any line would.
public struct StatusStripView: View {
    public let items: [DashboardItem]
    public let limit: Int
    public let height: CGFloat
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    public init(items: [DashboardItem], limit: Int, height: CGFloat = 10) {
        self.items = items
        self.limit = limit
        self.height = height
    }

    /// The *last* `limit` items: a history that outgrows its space should drop
    /// its oldest entries, not its newest.
    private var shown: [DashboardItem] {
        Array(items.suffix(limit))
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(shown) { item in
                let status = item.status ?? .unknown
                if differentiateWithoutColor {
                    Image(systemName: status.symbolName)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(height, 8))
                } else {
                    RoundedRectangle(cornerRadius: height / 3, style: .continuous)
                        .fill(status.tint.opacity(status == .unknown || status == .offline ? 0.3 : 1))
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityDescription))
    }

    private var accessibilityDescription: String {
        let counts = Dictionary(grouping: shown, by: { $0.status ?? .unknown })
            .sorted { $0.value.count > $1.value.count }
            .map { "\($0.value.count) \($0.key.label.lowercased())" }
        return "Last \(shown.count): " + counts.joined(separator: ", ")
    }
}
