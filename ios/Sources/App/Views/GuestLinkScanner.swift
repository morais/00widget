import SwiftUI
import AVFoundation
import VisionKit

/// Scans a shared link's QR code.
///
/// Reachable while signed out, which is the point: a guest may have no account
/// and no intention of making one. VisionKit does the recognition, so there is
/// no capture-session plumbing to maintain.
struct GuestLinkScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        try? controller.startScanning()
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        // A code stays in frame for many callbacks; without this the same link
        // is submitted dozens of times while the camera is still pointed at it.
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(items)
        }

        func dataScanner(_ scanner: DataScannerViewController, didUpdate items: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(items)
        }

        private func handle(_ items: [RecognizedItem]) {
            guard !hasScanned else { return }
            for case let .barcode(barcode) in items {
                guard
                    let payload = barcode.payloadStringValue,
                    let token = GuestToken.fromScannedText(payload)
                else { continue }
                hasScanned = true
                onScan(token)
                return
            }
        }
    }
}

/// Presents the scanner and reports what came of the token.
struct GuestLinkScannerSheet: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var status: String?
    @State private var isBusy = false
    @State private var cameraDenied = false

    var body: some View {
        NavigationStack {
            Group {
                if cameraDenied {
                    message(
                        icon: "video.slash",
                        text: "00Widget needs camera access to scan a code. Turn it on in Settings → 00Widget."
                    )
                } else if !GuestLinkScannerView.isSupported {
                    message(
                        icon: "qrcode.viewfinder",
                        text: "This device cannot scan codes. Ask the sender for the link instead — opening it does the same thing."
                    )
                } else {
                    ZStack(alignment: .bottom) {
                        GuestLinkScannerView { token in
                            Task { await accept(token) }
                        }
                        .ignoresSafeArea()

                        VStack(spacing: 8) {
                            if isBusy { ProgressView() }
                            Text(status ?? "Point the camera at a 00Widget QR code.")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .padding()
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Scan a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await checkCameraPermission() }
    }

    private func message(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func checkCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraDenied = false
        case .notDetermined:
            cameraDenied = !(await AVCaptureDevice.requestAccess(for: .video))
        default:
            cameraDenied = true
        }
    }

    private func accept(_ token: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        switch await env.acceptGuestLink(token: token) {
        case .added(let title):
            status = "Added “\(title)”."
            try? await Task.sleep(for: .milliseconds(700))
            dismiss()
        case .alreadyHeld(let title):
            status = "You already have “\(title)”."
            try? await Task.sleep(for: .milliseconds(700))
            dismiss()
        case .invalid:
            status = "That is not a 00Widget link."
        case .expired:
            status = "That link has expired or been revoked."
        case .failed(let message):
            status = message
        }
    }
}
