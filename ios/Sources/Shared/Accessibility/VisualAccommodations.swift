import SwiftUI

/// The two settings that say an appearance is not being read the way it is
/// drawn, and one answer for each, in one place.
///
/// `Increase Contrast` and `Reduce Transparency` are easy to answer badly by
/// answering them view by view: a card raises one opacity, the widget drawing
/// the same card does not, and the two disagree about what the setting meant.
/// The decisions therefore live here as pure functions the views call, next to
/// the reasoning for each, and the tests can reach them without a renderer.
///
/// What is deliberately *not* here: the system's own colours. `Color.orange`,
/// `.red`, `.green` and the rest already resolve to their high-contrast
/// variants under Increase Contrast, so nothing needs to darken them by hand —
/// only alpha, which the system does not touch, and translucency, which it
/// does not remove.
public enum VisualAccommodations {
    /// A mark that carries data — a bar, a stroke, an interval band.
    ///
    /// Halfway to opaque rather than opaque: several of these alphas *are* the
    /// encoding. `ChartSeriesPalette.opacity(for:)` separates a forecast from
    /// an actual by 0.4 of alpha, and flattening every role to 1 would trade a
    /// contrast problem for a meaning one. Halving the distance keeps the
    /// order and the gaps while putting the faintest role — a 0.35 capacity —
    /// above two thirds opaque. The role is also spoken, legended, and dashed,
    /// so alpha is the weakest of the four carriers and the right one to spend.
    public static func fillOpacity(_ base: Double, increasedContrast: Bool) -> Double {
        guard increasedContrast else { return base }
        return Swift.min(1, base + (1 - base) * 0.5)
    }

    /// A wash behind content — an area gradient under a line, a category band,
    /// a panel or ranked-row background.
    ///
    /// These start near-invisible on purpose, and text sits on several of
    /// them, so this raises rather than saturates and stops at the point where
    /// a background would start competing with what is written on it.
    public static func washOpacity(_ base: Double, increasedContrast: Bool) -> Double {
        guard increasedContrast else { return base }
        return Swift.min(0.55, base * 1.75)
    }

    /// A hairline that has to stay a hairline. A 1pt dashed reference rule is
    /// the faintest mark on a plot and the one most worth keeping.
    public static func ruleWidth(_ base: CGFloat, increasedContrast: Bool) -> CGFloat {
        increasedContrast ? base * 1.5 : base
    }

    /// For text coloured by a status or signal.
    ///
    /// A glyph keeps its tint under any setting — a checkmark is a checkmark
    /// whatever colour it is drawn in, and the colour is the second reading
    /// rather than the only one. Text is the opposite case: "Paused" in the
    /// status tint is the *word* carrying the meaning and the tint carrying
    /// nothing but a contrast risk, and `.secondary` grey — what `unknown` and
    /// `offline` resolve to — is the worst of them. Under Increase Contrast
    /// the word is drawn in the foreground colour and loses nothing.
    public static func textTint(_ tint: Color, increasedContrast: Bool) -> AnyShapeStyle {
        increasedContrast ? AnyShapeStyle(.primary) : AnyShapeStyle(tint)
    }

    /// What a material becomes when the viewer has asked for less
    /// transparency. Opaque, and not `.background`: these sit *on* content —
    /// a widget's own card, a camera preview — so they have to read as a
    /// surface above it rather than as a hole through it.
    public static var opaqueSurface: Color {
        #if os(tvOS)
        // Apple TV runs this app in a forced dark interface, so there is no
        // light variant to resolve and no system-background colour to ask.
        Color(white: 0.16)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

/// A material normally, a solid surface under Reduce Transparency.
///
/// A `ShapeStyle` rather than a `ViewModifier` so it drops into the
/// `.background(_:in:)` call sites unchanged, and so the resolution happens
/// where the environment is — including inside the widget extension, which
/// renders an archived view tree it never ran.
public struct AccommodatingMaterial: ShapeStyle {
    public init() {}

    public func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        environment.accessibilityReduceTransparency
            ? AnyShapeStyle(VisualAccommodations.opaqueSurface)
            : AnyShapeStyle(.ultraThinMaterial)
    }
}

public extension ShapeStyle where Self == AccommodatingMaterial {
    static var accommodatingMaterial: AccommodatingMaterial { AccommodatingMaterial() }
}
