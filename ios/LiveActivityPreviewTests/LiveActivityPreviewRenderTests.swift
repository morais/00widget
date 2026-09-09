import Foundation
import SwiftUI
import Testing
import UIKit
import WidgetKit

/// A batch visual inventory of every Lock Screen data shape.
///
/// The fixed point sizes are real widget canvases: the common 6.3-inch phone
/// and the narrow 4.7-inch phone that catches layouts which only fit on modern
/// hardware. Dynamic Island is deliberately not rendered here; the system
/// applies its width after SwiftUI has laid the regions out, so the native
/// `#Preview`s beside the widget are the cheap, authoritative loop for it.
@MainActor
@Suite("Live Activity preview gallery")
struct LiveActivityPreviewRenderTests {
    private struct Canvas {
        let suffix: String
        let size: CGSize
    }

    private let canvases = [
        Canvas(suffix: "iphone-6.3", size: CGSize(width: 364, height: 170)),
        Canvas(suffix: "iphone-4.7", size: CGSize(width: 321, height: 148))
    ]

    @Test("Compact fixtures reach every intended branch")
    func compactFixturesReachTheirBranches() {
        #expect(LiveActivityPreviewFixtures.countdown.state.compactTrailingChoice(widthLimited: false) == .countdown)
        #expect(LiveActivityPreviewFixtures.progress.state.compactTrailingChoice(widthLimited: false) == .ring)
        #expect(LiveActivityPreviewFixtures.compactCount.state.compactTrailingChoice(widthLimited: false) == .count)
        #expect(LiveActivityPreviewFixtures.compactToken.state.compactTrailingChoice(widthLimited: false) == .token)
    }

    @Test("Render every Lock Screen fixture")
    func renderEveryFixture() throws {
        let fileManager = FileManager.default
        let output = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("live-activity-previews", isDirectory: true)

        try? fileManager.removeItem(at: output)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

        var written: [String] = []
        for fixture in LiveActivityPreviewFixtures.all {
            for canvas in canvases {
                let filename = "\(fixture.id)--\(canvas.suffix).png"
                let view = LockScreenView(
                    attributes: fixture.attributes,
                    state: fixture.state,
                    systemIsStale: fixture.systemIsStale
                )
                .environment(\.activityFamily, .medium)
                .frame(width: canvas.size.width, height: canvas.size.height)
                .background(Color(white: 0.12))
                .environment(\.colorScheme, .dark)

                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.uiImage, "ImageRenderer returned no image for \(filename)")
                let data = try #require(image.pngData(), "Could not encode \(filename) as PNG")
                try data.write(to: output.appendingPathComponent(filename))
                written.append(filename)
            }
        }

        let manifest: [String: Any] = [
            "fixtures": LiveActivityPreviewFixtures.all.map { ["id": $0.id, "name": $0.name] },
            "files": written,
            "note": "ProgressView is UIKit-backed and needs a device for pixel-accurate bar fill. Geometry is representative."
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: output.appendingPathComponent("manifest.json"))

        #expect(written.count == LiveActivityPreviewFixtures.all.count * canvases.count)
        print("ZW_PREVIEW_DIR=\(output.path)")
    }
}
