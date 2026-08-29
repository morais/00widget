import CoreImage.CIFilterBuiltins
import SwiftUI

struct TVWebLink: Identifiable {
    let cardTitle: String
    let url: URL

    var id: String { "\(cardTitle)|\(url.absoluteString)" }
}

struct TVWebLinkView: View {
    @Environment(\.dismiss) private var dismiss
    let link: TVWebLink

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.03, blue: 0.05)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.clear, Color.accentColor.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 44) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(link.cardTitle)
                            .font(.largeTitle.weight(.bold))
                        Text("Open this link on your phone")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Back", systemImage: "chevron.backward") {
                        dismiss()
                    }
                }

                HStack(spacing: 72) {
                    VStack(alignment: .leading, spacing: 28) {
                        Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                            .font(.system(size: 88))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)

                        Text("Scan the QR code with your phone’s camera.")
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(link.url.absoluteString)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    .frame(maxWidth: 680, alignment: .leading)

                    Spacer(minLength: 0)

                    if let image = QRCode.image(for: link.url.absoluteString) {
                        image
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(34)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 32))
                            .frame(width: 430, height: 430)
                            .accessibilityLabel("QR code for \(link.url.absoluteString)")
                    } else {
                        ContentUnavailableView(
                            "Couldn’t create QR code",
                            systemImage: "qrcode",
                            description: Text(link.url.absoluteString)
                        )
                        .frame(width: 430, height: 430)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 60)
        }
    }
}

private enum QRCode {
    static func image(for value: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"

        let context = CIContext()
        guard
            let output = filter.outputImage,
            let cgImage = context.createCGImage(output, from: output.extent)
        else {
            return nil
        }
        return Image(decorative: cgImage, scale: 1)
    }
}
