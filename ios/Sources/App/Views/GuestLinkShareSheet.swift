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

                Text(expiryText(for: link.expiresAt))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

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

    /// "Stops working <date>" left people counting days in their head and said
    /// nothing about the other way a link ends. Lead with the duration, keep the
    /// exact moment for anyone who needs it, and name where to revoke.
    private func expiryText(for date: Date) -> String {
        let absolute = date.formatted(date: .abbreviated, time: .shortened)
        #if ZW_SHARING_ENABLED
        let revokeHint = "Settings → Manage sharing"
        #else
        let revokeHint = "Settings → Links you've shared"
        #endif
        return "Expires in \(relativeDuration(until: date)) (\(absolute)), or revoke it sooner in \(revokeHint)."
    }

    /// Whole hours below two days, whole days above. An activity link lasts 12
    /// hours, so "in 0 days" would be both wrong and the common case.
    private func relativeDuration(until date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 {
            if hours < 1 { return "less than an hour" }
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let days = Int((seconds / 86_400).rounded())
        return days == 1 ? "1 day" : "\(days) days"
    }

    private func mint() async {
        isLoading = true
        defer { isLoading = false }
        do {
            link = try await env.createGuestLink(resourceKind: resourceKind, resourceId: resourceId)
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
