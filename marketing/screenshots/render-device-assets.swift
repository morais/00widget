// Rasterize Device Hub's installed vector assets without a white PDF backdrop.
// Apple assets stay on the host; only generated promotional PNGs contain them.
import AppKit
import CoreGraphics

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, arguments.count % 3 == 0 else {
    fatalError("Usage: render-device-assets.swift input.pdf output.png scale [...]")
}
for index in stride(from: 0, to: arguments.count, by: 3) {
    let input = URL(fileURLWithPath: arguments[index])
    let output = URL(fileURLWithPath: arguments[index + 1])
    let scale = Double(arguments[index + 2])!
    guard let document = CGPDFDocument(input as CFURL), let page = document.page(at: 1) else {
        fatalError("Cannot read Device Hub asset: \(input.path)")
    }
    let bounds = page.getBoxRect(.mediaBox)
    let width = Int((bounds.width * scale).rounded())
    let height = Int((bounds.height * scale).rounded())
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Cannot allocate asset bitmap") }
    context.scaleBy(x: scale, y: scale)
    context.drawPDFPage(page)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output)
}
