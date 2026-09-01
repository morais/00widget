import SwiftUI

/// What tells two filled regions apart when their colours cannot.
///
/// `Differentiate Without Color` is not a monochrome mode — colour is still
/// drawn — it is a statement that colour is not being read. Everything on a
/// card that survives it already does: a status pip becomes its symbol, a
/// flow becomes an arrow, a reference rule's role becomes a dash pattern. What
/// did not survive it were the two places where several regions are filled
/// side by side and nothing but the fill says which is which — a `breakdown`
/// bar's segments, and a multi-series chart's columns.
///
/// A marker is one index's whole identity: the glyph its legend row draws and
/// the texture its region is filled with, kept together so the two cannot
/// drift. Four of them, which is the number of series the schema permits and
/// the number of colours `ChartSeriesPalette` allocates from. A `breakdown`
/// may carry more items than that, so they cycle: adjacent regions still
/// differ, which is what the bar needs, and the legend's order resolves the
/// rest — which is what Apple asks a colour-coded chart to provide.
///
/// The first marker is deliberately untextured. One series is the common case
/// and has nothing to be told apart from, so a plain chart looks the same
/// whether or not the setting is on.
public enum SeriesMarker: Int, CaseIterable, Sendable {
    case circle
    case square
    case triangle
    case diamond

    public static func at(_ index: Int) -> SeriesMarker {
        let all = SeriesMarker.allCases
        return all[((index % all.count) + all.count) % all.count]
    }

    /// The legend glyph. Filled rather than outlined: a legend swatch is a few
    /// points across, and an outline at that size is a smudge.
    public var symbolName: String {
        switch self {
        case .circle: return "circle.fill"
        case .square: return "square.fill"
        case .triangle: return "triangle.fill"
        case .diamond: return "diamond.fill"
        }
    }

    /// The texture drawn over this index's fill, or nil for a plain fill.
    public var hatch: SeriesHatch? {
        switch self {
        case .circle: return nil
        case .square: return .forwardDiagonal
        case .triangle: return .backDiagonal
        case .diamond: return .vertical
        }
    }
}

public enum SeriesHatch: Sendable {
    case forwardDiagonal
    case backDiagonal
    case vertical
}

/// Evenly spaced rules across whatever region it is clipped to.
///
/// Lines rather than dots, and stroked rather than filled, because this has to
/// read at both ends of the range it is used at: a 14-point composition bar on
/// a small widget and a 48-point one on a television. A dot pattern that is
/// legible at the second is a smear at the first.
public struct SeriesHatchShape: Shape {
    public let hatch: SeriesHatch
    public let spacing: CGFloat

    public init(hatch: SeriesHatch, spacing: CGFloat = 5) {
        self.hatch = hatch
        self.spacing = spacing
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0, spacing > 0 else { return path }

        switch hatch {
        case .vertical:
            var x = rect.minX + spacing / 2
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += spacing
            }
        case .forwardDiagonal, .backDiagonal:
            // A 45° rule leaves the region through the side it entered by,
            // displaced by the height — so the sweep has to start a full
            // height before the region and end a full height after it, or the
            // two corners it crosses are left bare.
            let rises = hatch == .forwardDiagonal
            var x = rect.minX - rect.height
            while x < rect.maxX + rect.height {
                path.move(to: CGPoint(x: x, y: rises ? rect.maxY : rect.minY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rises ? rect.minY : rect.maxY))
                x += spacing
            }
        }
        return path
    }
}

public extension Shape {
    /// Fills this shape, texturing it when colour is not being read.
    ///
    /// The texture is clipped to the shape itself rather than to its bounding
    /// box: a composition bar's segments are rounded and a chart's columns are
    /// separated by gaps, and a rule running through those gaps would join the
    /// regions it exists to separate.
    @ViewBuilder
    func seriesFill(
        _ style: some ShapeStyle,
        marker: SeriesMarker,
        textured: Bool,
        spacing: CGFloat = 5,
        lineWidth: CGFloat = 1
    ) -> some View {
        if textured, let hatch = marker.hatch {
            fill(style)
                .overlay {
                    SeriesHatchShape(hatch: hatch, spacing: spacing)
                        .stroke(Color.primary.opacity(0.55), lineWidth: lineWidth)
                        .clipShape(self)
                }
        } else {
            fill(style)
        }
    }
}

/// The legend swatch for one index: the marker's glyph when colour is not
/// being read, and the plain dot every legend has always drawn otherwise.
///
/// One view for every legend in the app — the breakdown key on a card, the
/// series key under a chart, the row swatch on Apple TV — so a swatch and the
/// region it names cannot end up describing different indices.
public struct SeriesSwatch: View {
    public let index: Int
    public let color: Color
    public let size: CGFloat
    public let differentiateWithoutColor: Bool

    public init(index: Int, color: Color, size: CGFloat, differentiateWithoutColor: Bool) {
        self.index = index
        self.color = color
        self.size = size
        self.differentiateWithoutColor = differentiateWithoutColor
    }

    public var body: some View {
        Group {
            if differentiateWithoutColor {
                Image(systemName: SeriesMarker.at(index).symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
