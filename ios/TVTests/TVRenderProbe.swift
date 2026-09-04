import SwiftUI
import UIKit

/// Measuring and rendering a tvOS view from a unit test.
///
/// A television's layout is the one thing in this repo that nothing else can
/// see. The compiler does not notice a `VStack` overflowing a fixed cell, a
/// green suite says nothing about it, and the capture that *would* show it is
/// a ten-minute `xcodebuild` run driving a real Home Screen. So the two things
/// this file offers are the two questions worth asking cheaply:
///
/// - `height(of:width:)` — what a view actually wants, via
///   `UIHostingController.sizeThatFits`. This is the measurement a fixed
///   `.frame(height:)` destroys, which is why the thing being measured has to
///   be the content rather than the cell around it.
/// - `write(_:size:named:)` — a PNG, via `ImageRenderer`, to look at.
///
/// Both need the whole of SwiftUI, which is why this target is hosted by the
/// tvOS app rather than being a plain logic bundle.
///
/// The caveat carried over from the iOS harness applies here too: anything
/// UIKit-backed renders wrong offscreen. A linear `ProgressView` comes back
/// full-width with a marker whatever its value, so a `progress` card's bar
/// proves nothing here and still needs a device. Type, spacing and stacking —
/// which is where every overflow in this file has come from — are faithful.
@MainActor
enum TVRenderProbe {
    /// The natural height of `view` when offered `width` and unlimited height.
    ///
    /// Offering `.greatestFiniteMagnitude` rather than the cell's height is
    /// the whole point: it asks what the content wants, not what it was told
    /// to be.
    static func height<V: View>(
        of view: V,
        width: CGFloat,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        size(of: view, fitting: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
             dynamicTypeSize: dynamicTypeSize).height
    }

    /// The natural width of `view` when height is the free dimension — what a
    /// row of text ideally wants before an `HStack` starts taking it away.
    static func width<V: View>(
        of view: V,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        size(of: view, fitting: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
             dynamicTypeSize: dynamicTypeSize).width
    }

    static func size<V: View>(
        of view: V,
        fitting proposal: CGSize,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGSize {
        let host = UIHostingController(rootView: view.dynamicTypeSize(dynamicTypeSize))
        // A hosting controller that has never loaded its view measures its
        // root view before SwiftUI has resolved the environment, and returns
        // zero for anything non-trivial.
        host.loadViewIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: proposal)
    }


    /// The bounding box of everything actually drawn, in the canvas's own
    /// coordinates, or nil if nothing was.
    ///
    /// This is the question `height(of:width:)` cannot answer. That one
    /// reports what a view *ideally* wants; it is measured before
    /// `minimumScaleFactor` has had its say, and every card on this dashboard
    /// relies on that shrinking to fit the box it is given. So an ideal height
    /// over budget is not by itself a bug — the bug is ink landing outside the
    /// card, which is what happens once a column needs more than shrinking can
    /// give back. Render into a canvas larger than the card and look at where
    /// the ink went.
    static func inkBounds<V: View>(
        of view: V,
        canvas: CGSize,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> CGRect? {
        let renderer = ImageRenderer(
            content: view
                .dynamicTypeSize(dynamicTypeSize)
                .frame(width: canvas.width, height: canvas.height)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 1
        guard let cg = renderer.uiImage?.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Writes a PNG and returns its path, for the times the number is not the
    /// answer and you have to look at the thing. Read it off the simulator
    /// with the path this prints.
    @discardableResult
    static func write<V: View>(
        _ view: V,
        size: CGSize,
        named name: String,
        dynamicTypeSize: DynamicTypeSize = .large,
        scale: CGFloat = 1
    ) -> String? {
        let renderer = ImageRenderer(
            content: view
                .dynamicTypeSize(dynamicTypeSize)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.12))
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = scale
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("WROTE \(url.path)")
        return url.path
    }
}
