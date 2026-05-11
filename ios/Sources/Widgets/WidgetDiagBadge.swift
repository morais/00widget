import SwiftUI
import WidgetKit

struct WidgetDiagBadge: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.85), in: Capsule())
            .foregroundStyle(.white)
            .padding(4)
    }

    private var label: String {
        let mode: String
        switch renderingMode {
        case .fullColor: mode = "FC"
        case .accented: mode = "AC"
        case .vibrant: mode = "VB"
        @unknown default: mode = "??"
        }
        let lum = isLuminanceReduced ? "L" : "."
        let scheme = colorScheme == .dark ? "D" : "L"
        return "\(mode)\(lum)\(scheme)"
    }
}
