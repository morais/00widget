import SwiftUI

/// tvOS 26 has no system text-size control, but tvOS 27 applies Dynamic Type
/// to the same SwiftUI environment used on iOS. These helpers compile and keep
/// today's measurements on tvOS 26 while making the custom television type and
/// dense layouts ready to respond when that environment starts changing.
extension DynamicTypeSize {
    var usesTVLargeTextLayout: Bool { isAccessibilitySize }
}

private struct TVScaledSystemFont: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight,
        design: Font.Design
    ) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaledSize, weight: weight, design: design))
    }
}

private struct TVReadableText: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let standardLineLimit: Int?
    let largeTextLineLimit: Int?
    let standardMinimumScaleFactor: CGFloat

    func body(content: Content) -> some View {
        let usesLargeText = dynamicTypeSize.usesTVLargeTextLayout
        content
            .lineLimit(usesLargeText ? largeTextLineLimit : standardLineLimit)
            // Enlarging text and immediately shrinking it back down defeats
            // the preference. Standard layouts keep their tuned fallback.
            .minimumScaleFactor(usesLargeText ? 1 : standardMinimumScaleFactor)
            .fixedSize(horizontal: false, vertical: usesLargeText)
    }
}

extension View {
    func tvScaledSystemFont(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(
            TVScaledSystemFont(
                size: size,
                relativeTo: textStyle,
                weight: weight,
                design: design
            )
        )
    }

    func tvReadableText(
        standardLineLimit: Int? = 1,
        largeTextLineLimit: Int? = nil,
        standardMinimumScaleFactor: CGFloat = 1
    ) -> some View {
        modifier(
            TVReadableText(
                standardLineLimit: standardLineLimit,
                largeTextLineLimit: largeTextLineLimit,
                standardMinimumScaleFactor: standardMinimumScaleFactor
            )
        )
    }
}
