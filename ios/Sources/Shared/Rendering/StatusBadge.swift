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
            Circle()
                .fill(status.tint)
                .frame(width: 8, height: 8)
            if !compact {
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
