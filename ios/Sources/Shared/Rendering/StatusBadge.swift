import SwiftUI

public struct StatusBadge: View {
    public let status: DashboardStatus
    public let compact: Bool

    public init(status: DashboardStatus, compact: Bool = false) {
        self.status = status
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(status.tint)
            if !compact {
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(status.label)
    }
}
