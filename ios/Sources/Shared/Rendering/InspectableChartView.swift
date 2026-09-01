import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// The detail-only reading of a chart. Widgets keep the glanceable static
/// sparkline; a detail screen gets exact values and one selection shared by
/// touch, the Siri Remote, and accessibility adjustable actions.
public struct InspectableChartView: View {
    public let chart: DashboardChart
    public let tint: Color
    /// The card or activity this plot belongs to. Spoken by the audio graph,
    /// which opens as a surface of its own and would otherwise be a nameless
    /// series of tones.
    public let title: String?
    public let unit: String?
    public let plotHeight: CGFloat
    public let lineWidth: CGFloat
    public let compact: Bool

    @State private var selectedIndex: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    public init(
        chart: DashboardChart,
        tint: Color,
        title: String? = nil,
        unit: String? = nil,
        plotHeight: CGFloat = 180,
        lineWidth: CGFloat = 3,
        compact: Bool = false
    ) {
        self.chart = chart
        self.tint = tint
        self.title = title
        self.unit = unit
        self.plotHeight = plotHeight
        self.lineWidth = lineWidth
        self.compact = compact
        _selectedIndex = State(initialValue: max(0, chart.points.count - 1))
    }

    private var snapshot: ChartInspectionSnapshot? {
        chart.inspection(at: selectedIndex, unit: unit)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            GeometryReader { proxy in
                interactivePlot(width: proxy.size.width)
            }
            .frame(height: plotHeight)

            if let snapshot {
                selectionPanel(snapshot)
            }
        }
        .onChange(of: chart.points.count) { _, count in
            selectedIndex = min(max(0, selectedIndex), max(0, count - 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("chart-inspector")
        .accessibilityLabel("Chart values")
        .accessibilityValue(snapshot?.accessibilityDescription(unit: unit) ?? "No chart data")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: 1)
            case .decrement: move(by: -1)
            @unknown default: break
            }
        }
        // Stepping the selection answers "what is this point?"; the audio
        // graph answers "what shape is this?", which is the question a metric
        // dashboard is usually asked and the one a list of numbers answers
        // worst. VoiceOver offers it on this element's rotor.
        .accessibilityChartDescriptor(
            ChartAudioGraph(chart: chart, title: title, unit: unit)
        )
    }

    @ViewBuilder
    private func interactivePlot(width: CGFloat) -> some View {
        let plot = ZStack {
            SparklineView(chart: chart, tint: tint, lineWidth: lineWidth)
            selectionIndicator(width: width)
        }
        .contentShape(Rectangle())

        #if os(tvOS)
        plot
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? tint.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isFocused ? tint : Color.secondary.opacity(0.22), lineWidth: isFocused ? 4 : 1)
            )
            .focusable()
            .focused($isFocused)
            .background {
                TVRemoteSwipeCapture(isActive: isFocused) { direction in
                    move(by: direction * remoteSwipeDistance)
                }
            }
            .onMoveCommand { direction in
                switch direction {
                case .left: move(by: -1)
                case .right: move(by: 1)
                default: break
                }
            }
        #else
        plot
            .overlay {
                IOSChartGestureCapture { x, gestureWidth in
                    select(at: x, width: gestureWidth)
                }
            }
        #endif
    }

    @ViewBuilder
    private func selectionIndicator(width: CGFloat) -> some View {
        if !chart.points.isEmpty {
            let count = chart.points.count
            let categorical = chart.style != .line
            let slot = width / CGFloat(max(1, count))
            let x = categorical
                ? slot * (CGFloat(selectedIndex) + 0.5)
                : (count == 1 ? width / 2 : width * CGFloat(selectedIndex) / CGFloat(count - 1))

            ZStack(alignment: .topLeading) {
                if categorical {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            tint.opacity(
                                VisualAccommodations.washOpacity(0.12, increasedContrast: increasedContrast)
                            )
                        )
                        .frame(width: max(4, slot * 0.78), height: plotHeight)
                        .offset(x: x - max(4, slot * 0.78) / 2)
                }
                Rectangle()
                    .fill(tint.opacity(0.9))
                    .frame(width: 2, height: plotHeight)
                    .offset(x: min(max(0, x - 1), max(0, width - 2)))
            }
            // Offsets do not contribute to layout. Without an explicit plot
            // frame this ZStack is only as wide as the 2pt selection rule, so
            // its origin is centred by the parent and every x position is
            // displaced by roughly half the chart width.
            .frame(width: width, height: plotHeight, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func selectionPanel(_ snapshot: ChartInspectionSnapshot) -> some View {
        let readings = snapshot.values.filter { $0.kind != .reference }
        let reference = snapshot.values.first { $0.kind == .reference }
        let showsHeader = snapshot.label != nil || snapshot.signal != nil

        return VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            if showsHeader {
                selectionHeader(label: snapshot.label, signal: snapshot.signal)
            }

            ForEach(Array(readings.enumerated()), id: \.element.id) { index, value in
                readingRow(value, index: index)
            }

            if let reference {
                referenceRow(reference, snapshot: snapshot, index: readings.count)
            }
        }
        .padding(compact ? 10 : 14)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                .fill(
                    Color.secondary.opacity(
                        VisualAccommodations.washOpacity(0.10, increasedContrast: increasedContrast)
                    )
                )
        )
    }

    @ViewBuilder
    private func selectionHeader(label: String?, signal: MetricSignal?) -> some View {
        if usesStackedSelectionLayout {
            VStack(alignment: .leading, spacing: 4) {
                selectionHeaderContent(label: label, signal: signal)
            }
        } else {
            HStack(spacing: 8) {
                selectionHeaderContent(label: label, signal: signal)
                Spacer(minLength: 8)
            }
        }
    }

    @ViewBuilder
    private func selectionHeaderContent(label: String?, signal: MetricSignal?) -> some View {
        if let label {
            Text(label)
                .font(headerFont)
                .inspectableChartText(tvLineLimit: 1)
        }
        if let signal {
            Label(signal.rawValue.capitalized, systemImage: signal.symbolName)
                .font(semanticFont)
                .foregroundStyle(
                    VisualAccommodations.textTint(signal.tint, increasedContrast: increasedContrast)
                )
                .inspectableChartText(tvLineLimit: 1)
        }
    }

    @ViewBuilder
    private func readingRow(_ value: ChartInspectionValue, index: Int) -> some View {
        if usesStackedSelectionLayout {
            VStack(alignment: .leading, spacing: 4) {
                readingDescriptor(value, index: index)
                readingValue(value)
                    .padding(.leading, selectionValueIndent)
            }
        } else {
            HStack(spacing: 8) {
                readingDescriptor(value, index: index)
                Spacer(minLength: 8)
                readingValue(value)
            }
        }
    }

    private func readingDescriptor(_ value: ChartInspectionValue, index: Int) -> some View {
        HStack(spacing: 8) {
            valueMarker(value, index: index)
            SemanticFlowIcon(value.semantic, font: semanticFont)
            if value.kind != .value, let label = value.label {
                Text(label)
                    .font(valueFont)
                    .inspectableChartText(tvLineLimit: nil)
            }
            if let words = value.semantic?.accessibilityWords, !words.isEmpty {
                Text(words.joined(separator: " · "))
                    .font(semanticFont)
                    .foregroundStyle(.secondary)
                    .inspectableChartText(tvLineLimit: 1)
            }
        }
    }

    private func readingValue(_ value: ChartInspectionValue) -> some View {
        Text(ChartInspectionSnapshot.format(value.value, unit: unit))
            .font(valueFont.weight(.semibold))
            .monospacedDigit()
            .inspectableChartText(tvLineLimit: 1)
    }

    @ViewBuilder
    private func referenceRow(
        _ reference: ChartInspectionValue,
        snapshot: ChartInspectionSnapshot,
        index: Int
    ) -> some View {
        if usesStackedSelectionLayout {
            VStack(alignment: .leading, spacing: 4) {
                referenceDescriptor(reference, index: index)
                VStack(alignment: .leading, spacing: 2) {
                    referenceValue(reference)
                    referenceComparison(snapshot)
                }
                .padding(.leading, selectionValueIndent)
            }
        } else {
            HStack(spacing: 8) {
                referenceDescriptor(reference, index: index)
                referenceValue(reference)
                Spacer(minLength: 6)
                referenceComparison(snapshot)
            }
        }
    }

    private func referenceDescriptor(_ reference: ChartInspectionValue, index: Int) -> some View {
        HStack(spacing: 8) {
            valueMarker(reference, index: index)
            SemanticFlowIcon(reference.semantic, font: semanticFont)
            if let label = reference.label {
                Text(label)
                    .font(semanticFont)
                    .inspectableChartText(tvLineLimit: 1)
            }
        }
    }

    private func referenceValue(_ reference: ChartInspectionValue) -> some View {
        Text(ChartInspectionSnapshot.format(reference.value, unit: unit))
            .font(semanticFont)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .inspectableChartText(tvLineLimit: 1)
    }

    @ViewBuilder
    private func referenceComparison(_ snapshot: ChartInspectionSnapshot) -> some View {
        if let difference = snapshot.referenceDifference {
            Text(referenceDifferenceText(difference))
                .font(valueFont.weight(.semibold))
                .monospacedDigit()
                .inspectableChartText(tvLineLimit: 1)
        } else if let comparison = snapshot.referenceComparison {
            Text(comparison)
                .font(valueFont.weight(.semibold))
                .monospacedDigit()
                .inspectableChartText(tvLineLimit: 1)
        }
    }

    private var increasedContrast: Bool { colorSchemeContrast == .increased }

    private var usesStackedSelectionLayout: Bool {
        #if os(iOS) || os(tvOS)
        dynamicTypeSize.isAccessibilitySize
        #else
        false
        #endif
    }

    private var selectionValueIndent: CGFloat {
        markerSize + 8
    }

    @ViewBuilder
    private func valueMarker(_ value: ChartInspectionValue, index: Int) -> some View {
        if value.kind == .reference {
            Image(systemName: "minus")
                .foregroundStyle(markerTint(for: value, index: index))
        } else {
            // The same glyph the plot's legend and columns carry for this
            // series, so a reading in the panel can be matched to the region
            // it came from without reading either colour.
            SeriesSwatch(
                index: seriesIndex(for: value) ?? index,
                color: markerTint(for: value, index: index),
                size: markerSize,
                differentiateWithoutColor: differentiateWithoutColor
            )
        }
    }

    /// Where this reading sits in `chart.series`, which is the index every
    /// other surface allocates its colour and marker from. A total or a lone
    /// value belongs to no series and falls back to its row position.
    private func seriesIndex(for value: ChartInspectionValue) -> Int? {
        guard value.kind == .series, let series = chart.series else { return nil }
        return series.firstIndex { value.id == "series-\($0.id)" }
    }

    private func markerTint(for value: ChartInspectionValue, index: Int) -> Color {
        if value.kind == .series,
           let series = chart.series,
           let seriesIndex = series.firstIndex(where: { value.id == "series-\($0.id)" }) {
            let semantics = series.map { chart.resolvedSemantic(for: $0) }
            return ChartSeriesPalette.seriesTints(semantics: semantics)[seriesIndex]
        }
        return ChartSeriesPalette.tint(index: index, base: tint, semantic: value.semantic)
    }

    private func referenceDifferenceText(_ difference: Double) -> String {
        if abs(difference) < 0.000_001 { return "Matches" }
        let amount = ChartInspectionSnapshot.format(abs(difference), unit: unit)
        return "\(amount) \(difference > 0 ? "above" : "below")"
    }

    private var markerSize: CGFloat {
        #if os(tvOS)
        compact ? 10 : 14
        #else
        8
        #endif
    }

    private var headerFont: Font {
        #if os(tvOS)
        compact ? .headline : .title3.weight(.semibold)
        #else
        .headline
        #endif
    }

    private var valueFont: Font {
        #if os(tvOS)
        compact ? .callout : .headline
        #else
        .subheadline
        #endif
    }

    private var semanticFont: Font {
        #if os(tvOS)
        compact ? .caption : .callout
        #else
        .caption
        #endif
    }

    private func select(at x: CGFloat, width: CGFloat) {
        guard width > 0, !chart.points.isEmpty else { return }
        let fraction = min(max(0, x / width), 1)
        let index: Int
        if chart.style == .line, chart.points.count > 1 {
            index = Int((fraction * CGFloat(chart.points.count - 1)).rounded())
        } else {
            index = min(chart.points.count - 1, Int(fraction * CGFloat(chart.points.count)))
        }
        setSelection(index)
    }

    private func move(by offset: Int) {
        setSelection(selectedIndex + offset)
    }

    #if os(tvOS)
    private var remoteSwipeDistance: Int {
        // A touch-surface gesture is the page-sized counterpart to a one-point
        // directional click. Six swipes cross a normal series, capped so a
        // long chart still remains inspectable rather than jumping end to end.
        min(12, max(3, (chart.points.count + 5) / 6))
    }
    #endif

    private func setSelection(_ index: Int) {
        guard !chart.points.isEmpty else { return }
        let clamped = min(max(0, index), chart.points.count - 1)
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

/// iOS text is allowed to grow vertically; tvOS retains the line limits its
/// fixed card and detail layouts were designed around. Keeping that split here
/// prevents an iOS Dynamic Type fix from subtly changing the television grid.
private struct InspectableChartTextScaling: ViewModifier {
    let tvLineLimit: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fixedSize(horizontal: false, vertical: true)
        #else
        content
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : tvLineLimit)
            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
        #endif
    }
}

private extension View {
    func inspectableChartText(tvLineLimit: Int?) -> some View {
        modifier(InspectableChartTextScaling(tvLineLimit: tvLineLimit))
    }
}

#if os(iOS)
/// A horizontal pan must fail before it begins when the finger is moving
/// vertically. SwiftUI's `DragGesture` keeps participating after that choice,
/// which makes the surrounding detail `ScrollView` feel sticky over the plot.
private struct IOSChartGestureCapture: UIViewRepresentable {
    let onSelection: (_ x: CGFloat, _ width: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSelection = onSelection
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSelection: (_ x: CGFloat, _ width: CGFloat) -> Void

        init(onSelection: @escaping (_ x: CGFloat, _ width: CGFloat) -> Void) {
            self.onSelection = onSelection
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            publishLocation(from: recognizer)
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            publishLocation(from: recognizer)
        }

        private func publishLocation(from recognizer: UIGestureRecognizer) {
            guard let view = recognizer.view, view.bounds.width > 0 else { return }
            onSelection(recognizer.location(in: view).x, view.bounds.width)
        }
    }
}
#endif

#if os(tvOS)
/// SwiftUI's move command represents a directional click on the Siri Remote,
/// while a touch-surface gesture is an indirect pan. Install a pan recognizer
/// on the window so it participates alongside the focus engine instead of
/// losing the gesture to it. A discrete `UISwipeGestureRecognizer` used here
/// previously never won that competition on a physical remote, so every swipe
/// fell through to the one-point move command and appeared unaccelerated.
private struct TVRemoteSwipeCapture: UIViewRepresentable {
    let isActive: Bool
    let onSwipe: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, onSwipe: onSwipe)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onSwipe = onSwipe
        context.coordinator.attach(to: uiView.window)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        uiView.onWindowChange = nil
        coordinator.attach(to: nil)
    }

    final class AttachmentView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isActive: Bool
        var onSwipe: (Int) -> Void
        private weak var attachedWindow: UIWindow?
        private weak var recognizer: UIPanGestureRecognizer?

        init(isActive: Bool, onSwipe: @escaping (Int) -> Void) {
            self.isActive = isActive
            self.onSwipe = onSwipe
        }

        func attach(to window: UIWindow?) {
            guard attachedWindow !== window else { return }
            if let recognizer { attachedWindow?.removeGestureRecognizer(recognizer) }
            attachedWindow = window

            guard let window else { return }
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isActive
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The focus engine owns its own remote recognizer. Let both observe
            // the gesture: focus remains on the chart while this recognizer
            // turns the same touch into a page-sized value move.
            true
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard isActive, recognizer.state == .ended || recognizer.state == .cancelled else { return }
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            guard abs(translation.x) > abs(translation.y) else { return }
            // A small resting movement on the clickpad is not a swipe. Accept
            // either real travel or a quick flick, since both are natural on
            // the two generations of Siri Remote touch surface.
            guard abs(translation.x) >= 24 || abs(velocity.x) >= 250 else { return }
            let horizontal = abs(velocity.x) >= 250 ? velocity.x : translation.x
            onSwipe(horizontal < 0 ? -1 : 1)
        }
    }
}
#endif
