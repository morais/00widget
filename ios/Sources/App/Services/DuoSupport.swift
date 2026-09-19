import SwiftUI
import UIKit

/// iOS 27.1's hinge/seam query for foldable devices (`iPhone Duo` in the
/// simulator device list), `UIView.reservedRegions(kind:)`.
///
/// Every reference to that API in this target goes through here, for the
/// same reason as `Sources/Widgets/FullPageWidgetFamily.swift`: naming it is
/// a compile-time decision, and the repository is built against two SDKs —
/// iOS 27.1 on the development machine, iOS 27.0 on the machine that
/// archives for the App Store. The symbol does not merely become
/// unavailable on the older SDK the way `systemExtraLargePortrait` does; it
/// is absent there entirely, so the same `#if canImport(_version:)` gate is
/// still the right tool, just pointed at UIKit's own module version rather
/// than a coarse leading number. UIKit's `-user-module-version` is
/// `9127.0.84.1.116` on the iOS 27.0 SDK and `9127.0.85.28` on iOS 27.1 —
/// the same leading component (9127) on both, so the coarse `_version: 9127`
/// style this repo uses for WidgetKit/AppIntents would not discriminate the
/// two SDKs here. The full dotted version is required instead.
///
/// WidgetKit and AppIntents gained no new symbols in the 27.1 SDK (their
/// interfaces are otherwise byte-identical to 27.0), so `FullPageWidgetFamily`
/// and `SpotlightReindexing` are unaffected by this bump and need no changes.
enum DuoSupport {

    /// The device's hinge, in the coordinate space of `view`, or nil when
    /// there is none, the SDK can't name the API, the OS doesn't implement
    /// it, or `view`'s own scene isn't currently spanning it.
    ///
    /// `isActive` does *not* mean "the device is physically unfolded" —
    /// verified on an iPhone Duo simulator that an ordinary, non-spanning
    /// scene still gets a `division` region back, at `isActive == false`,
    /// even while genuinely unfolded onto the larger inner display. It means
    /// "this view's own content is currently drawn split across the seam,"
    /// which only happens once a scene opts into `UIArrangementViewController`
    /// to span both leaves. A single-panel scene — everything this app does
    /// today — always reads nil here, on every device, without a separate
    /// idiom check first.
    static func hingeFrame(in view: UIView) -> CGRect? {
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            return view.reservedRegions(kind: .division)
                .first(where: \.isActive)?
                .frame
        }
        #endif
        return nil
    }
}

/// Bridges `DuoSupport.hingeFrame(in:)` into SwiftUI the way `GeometryReader`
/// bridges a view's size: `content` is handed the hinge's frame, in the
/// coordinate space of whatever this wraps, or nil on every device without
/// one. Needs a live `UIView` to ask, which is why this is a representable
/// probe rather than a plain function — there is no SwiftUI environment
/// value for it in this SDK (checked: the 27.1 SwiftUI interface carries no
/// hinge-related additions, only the UIKit ones this type wraps).
struct DuoHingeReader<Content: View>: View {
    @State private var hinge: CGRect?
    @ViewBuilder var content: (CGRect?) -> Content

    var body: some View {
        content(hinge)
            .background(Probe(hinge: $hinge))
    }

    /// `layoutSubviews`, not `updateUIView`: the hinge query needs the
    /// probe's own frame to be final, and `updateUIView` runs on every
    /// SwiftUI body re-evaluation, not on every layout pass — the same
    /// distinction that keeps a `GeometryReader` out of this List's rows
    /// elsewhere in this file (see the comment on the outer reader in
    /// `DashboardView.content`).
    private final class ProbeView: UIView {
        var onChange: ((CGRect?) -> Void)?
        private var reported: CGRect?
        private var hasReported = false

        override func layoutSubviews() {
            super.layoutSubviews()
            let frame = DuoSupport.hingeFrame(in: self)

            // Two things this must not do, both seen on a device. Reporting
            // the same frame twice loops: the state write re-renders, the
            // re-render lays out, and layout lands back here. And writing
            // SwiftUI state *during* a layout pass is undefined — SwiftUI
            // either drops the update (the hinge never arrives, and the grid
            // silently keeps the width-only split) or applies it against a
            // layout already in flight, which after a rotation leaves the
            // List sized for the orientation it just left and runs the
            // second column off the screen. Hand it to the next runloop turn
            // instead, where it is an ordinary state change.
            guard !hasReported || frame != reported else { return }
            hasReported = true
            reported = frame
            DispatchQueue.main.async { [weak self] in self?.onChange?(frame) }
        }
    }

    private struct Probe: UIViewRepresentable {
        @Binding var hinge: CGRect?

        func makeUIView(context: Context) -> ProbeView {
            let view = ProbeView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.onChange = { hinge = $0 }
            return view
        }

        func updateUIView(_ uiView: ProbeView, context: Context) {}
    }
}
