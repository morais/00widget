import SwiftUI

public struct ProgressRow: View {
    public let progress: Double
    public let label: String?

    public init(progress: Double, label: String? = nil) {
        self.progress = progress
        self.label = label
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: max(0, min(progress, 1)))
                .progressViewStyle(.linear)
        }
    }
}
