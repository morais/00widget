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

/// The one consistent hand-off label used when a card or activity has reached
/// a decision that belongs to its operator.
public struct AttentionBadge: View {
    public let compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.caption2.weight(.semibold))
            if !compact {
                Text("Needs you")
                    .font(.caption2.weight(.semibold))
            }
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, compact ? 0 : 6)
        .padding(.vertical, compact ? 0 : 3)
        .background {
            if !compact {
                Capsule().fill(Color.orange.opacity(0.14))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Needs your attention")
    }
}
