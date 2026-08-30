import SwiftUI

/// A non-color reading of an item's direction, shared by card and activity
/// rows. Color remains useful, but the arrow makes the meaning survive tinted,
/// monochrome, and accessibility presentations.
public struct SemanticFlowIcon: View {
    public let flow: MetricFlow?
    public var font: Font

    public init(_ semantic: MetricSemantic?, font: Font = .caption2) {
        flow = semantic?.flow
        self.font = font
    }

    @ViewBuilder
    public var body: some View {
        if let flow {
            Image(systemName: flow == .inbound ? "arrow.down.left" : "arrow.up.right")
                .font(font)
                .foregroundStyle(.secondary)
                .accessibilityLabel(flow.rawValue)
        }
    }
}
