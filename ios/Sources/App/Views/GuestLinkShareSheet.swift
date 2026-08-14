import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders a guest link as a QR code so it can be handed over in person.
///
/// The link's token lives in the URL fragment, so what gets encoded here is the
/// whole URL — scanning it on a device with 00Widget installed opens the app
/// through the universal link, and anywhere else it opens the browser fallback.
struct GuestLinkShareSheet: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    let resourceKind: String
    let resourceId: String
    let title: String

    @State private var link: APIClient.GuestLinkResponse?
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Creating link…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let link {
                    content(for: link)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(error ?? "Could not create a link.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Share \(title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await mint() }
    }

    @ViewBuilder
    private func content(for link: APIClient.GuestLinkResponse) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                if let image = QRCode.image(for: link.url) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .padding(16)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("QR code for the shared link")
                }

                Text("Anyone with this code can see \(title) — and nothing else on your account. They cannot run actions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("Stops working \(link.expiresAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ShareLink(item: link.url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(20)
        }
    }

    private func mint() async {
        isLoading = true
        defer { isLoading = false }
        guard let client = env.apiClient() else {
            error = "Sign in first to share."
            return
        }
        do {
            link = try await client.createGuestLink(resourceKind: resourceKind, resourceId: resourceId)
        } catch let apiError as APIClientError where apiError.status == 403 {
            error = AppEnvironment.reauthorizationMessage
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum QRCode {
    /// CoreImage rather than a dependency: the Worker hand-rolls its router to
    /// stay framework-free and the app should hold the same line.
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // A shared link is long enough that the default correction level makes
        // a dense code; "M" keeps it scannable from a phone screen.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // The generator emits one pixel per module, which renders as mush.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
