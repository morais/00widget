import SwiftUI

/// The bar drawn behind a `list` row whose item carries an `amount`.
///
/// It sits in the row's background rather than under its text: a list is worth
/// the template precisely when several rows fit, and giving each row a second
/// line of chrome would halve that. The comparison is what the bar adds; the
/// numbers are already on the row.
public struct RankedRowBar: View {
    public let fraction: Double
    public let tint: Color

    public init(fraction: Double, tint: Color) {
        self.fraction = fraction
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: Swift.max(0, proxy.size.width * fraction))
        }
    }
}

public enum RankedRows {
    /// Fraction of the widest bar, keyed by item id.
    ///
    /// Measured against the largest amount rather than the total: a list ranks
    /// rows against each other, where a breakdown divides a whole. Nil when no
    /// item carries an amount, which is what keeps an ordinary list ordinary —
    /// the bars appear only for publishers that asked for them.
    public static func fractions(for items: [DashboardItem]) -> [String: Double]? {
        let amounts = items.compactMap { $0.amount }
        guard !amounts.isEmpty, let largest = amounts.map({ Swift.max(0, $0) }).max(), largest > 0 else {
            return nil
        }
        var fractions: [String: Double] = [:]
        for item in items {
            guard let amount = item.amount else { continue }
            fractions[item.id] = Swift.max(0, amount) / largest
        }
        return fractions
    }
}
