import SwiftUI

/// tvOS 26 has no system text-size control, but tvOS 27 applies Dynamic Type
/// to the same SwiftUI environment used on iOS. These helpers compile and keep
/// today's measurements on tvOS 26 while making the custom television type and
/// dense layouts respond when that environment starts changing.
///
/// Nothing here is new API. tvOS 27 adds a *setting*, not a symbol: the size
/// arrives in `dynamicTypeSize`, `@ScaledMetric` and `UIFontMetrics`, all of
/// which have been in the tvOS SDK for years. That is deliberate and worth
/// knowing before reaching for a compile-time gate — the whole file builds
/// against the tvOS 26 SDK on the submission machine and against 27 here,
/// with no `#if` anywhere, because there is no 27-only symbol to guard. The
/// module versions are recorded in AGENTS.md should one ever be needed.

/// How far the television's layout has to move for the text size in force.
///
/// Three steps rather than the boolean this replaces, because tvOS 27
/// publishes the *whole* `DynamicTypeSize` range and its two halves need
/// different answers. The boolean was `isAccessibilitySize`, which left the
/// middle of the range as the worst case in the app: the four sizes between
/// `.large` and `.accessibility1` enlarge every font by up to about a third
/// while a grid cell keeps its fixed 252-point height, and a `VStack` handed
/// less height than it needs does not compress — it overflows, centred,
/// straight through the padding around it. Nothing in a build, a warning, or
/// the suite sees that. The same sizes also kept `minimumScaleFactor`, which
/// shrinks the enlarged text back down and hands the viewer their old layout
/// with none of the size they asked for.
///
/// On tvOS 26 this is always `.standard` and nothing about the app changes.
enum TVTextScale {
    /// `.xSmall` … `.large`. What tvOS 26 always reports, and what every
    /// measurement in this app was tuned against.
    case standard
    /// `.xLarge` … `.xxxLarge`. Type grows by up to about a third. The
    /// three-column grid still holds, with taller cells and no shrinking.
    case enlarged
    /// `.accessibility1` and up. Rows stack, the grid drops a column, and
    /// fixed heights are given up altogether.
    case accessibility

    init(_ size: DynamicTypeSize) {
        if size.isAccessibilitySize {
            self = .accessibility
        } else {
            self = size > .large ? .enlarged : .standard
        }
    }

    /// The grid cell's fixed height, or nil where the row may grow.
    var cardHeight: CGFloat? {
        switch self {
        case .standard: return TVCardMetrics.height
        case .enlarged: return TVCardMetrics.enlargedHeight
        case .accessibility: return nil
        }
    }

    var cardMinimumHeight: CGFloat? {
        self == .accessibility ? 360 : nil
    }

    /// The Live Activity card is a `minHeight` rather than a fixed frame — it
    /// is one full-width row, so growing it cannot make a row go ragged.
    var liveActivityMinimumHeight: CGFloat {
        switch self {
        case .standard: return 260
        case .enlarged: return 320
        case .accessibility: return 360
        }
    }

    var widgetColumnCount: Int {
        self == .accessibility ? 2 : 3
    }

    /// Whether text may shrink to fit instead of wrapping. Only at standard
    /// size, where the fallback was tuned; anywhere else it would undo the
    /// preference it is responding to.
    var allowsShrinkToFit: Bool { self == .standard }

    /// Whether a line limit tuned for standard type should give way to the
    /// looser one. Both enlarged and accessibility sizes need it: a headline
    /// that fitted one line at 44 points does not at 59.
    var relaxesLineLimits: Bool { self != .standard }

    /// How many rows of a detail panel's column fit, given how many fit at
    /// standard size.
    ///
    /// One ratio for every list on that panel rather than four tuned ladders.
    /// The panel's height is fixed at the screen's 1080 lines however large
    /// the type is, and a row's height is essentially its type's, so what fits
    /// scales with the inverse of the type ramp: enlarged tops out near 1.35x
    /// standard and accessibility sizes near 1.6x. Never below two, because
    /// one row is a list that has stopped being one.
    func rowLimit(standard: Int) -> Int {
        let ratio: Double
        switch self {
        case .standard: return standard
        case .enlarged: ratio = 1.35
        case .accessibility: ratio = 1.6
        }
        return Swift.max(2, Int((Double(standard) / ratio).rounded(.down)))
    }
}

extension DynamicTypeSize {
    /// The *layout* switch: rows stacking, a column being dropped, a fixed
    /// height being given up. Deliberately still accessibility-only — type
    /// scales across the whole range, but rearranging a television's grid for
    /// a one-step size change would be a bigger change than the one asked for.
    var usesTVLargeTextLayout: Bool { TVTextScale(self) == .accessibility }
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
        let scale = TVTextScale(dynamicTypeSize)
        content
            .lineLimit(scale.relaxesLineLimits ? largeTextLineLimit : standardLineLimit)
            // Enlarging text and immediately shrinking it back down defeats
            // the preference. Only standard size keeps its tuned fallback.
            .minimumScaleFactor(scale.allowsShrinkToFit ? standardMinimumScaleFactor : 1)
            // A wrapped line needs the height to wrap into. Enlarged sizes
            // grow inside a taller cell; accessibility sizes grow into a cell
            // that has stopped being a fixed height at all.
            .fixedSize(horizontal: false, vertical: scale != .standard)
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
