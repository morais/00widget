import WidgetKit
import SwiftUI
import ActivityKit

struct ZeroZeroWidgetLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ZeroZeroWidgetActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(LiveActivityBackground.tint(for: context.attributes.kind))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(tapURL(for: context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.title, systemImage: iconName(attributes: context.attributes, state: context.state))
                        .font(.caption)
                        .foregroundStyle(context.attributes.kind.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if context.state.showsItemCount {
                            Text("\(context.state.activeItems.count) active")
                                .font(.headline)
                        } else if let endsAt = context.state.endsAt {
                            LiveActivityCountdownText(
                                endsAt: endsAt,
                                granularity: context.state.countdownGranularity
                            )
                                .font(.headline)
                                .monospacedDigit()
                        } else if let value = context.state.value {
                            HStack(spacing: 2) {
                                Text(value).font(.headline)
                                if let unit = context.state.unit {
                                    Text(unit).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text(context.state.state.capitalized)
                                .font(.headline)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    if context.state.activeItems.isEmpty, let subtitle = context.state.subtitle {
                        Text(subtitle).font(.caption)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.activeItems.isEmpty {
                        VStack(spacing: 5) {
                            ForEach(Array(context.state.activeItems.prefix(3))) { item in
                                LiveActivityItemRow(item: item, condensed: true)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    } else if let chart = context.state.chart, chart.isRenderable {
                        // Ranked above progress: a producer sending both has a
                        // number that moves, and the plot says which way while
                        // a bar only says how far.
                        SparklineView(chart: chart, tint: context.attributes.kind.tint, lineWidth: 1.5)
                            .frame(height: 26)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)
                    } else if let p = context.state.progress, context.state.endsAt == nil {
                        ProgressView(value: max(0, min(p, 1)))
                            .progressViewStyle(.linear)
                    }
                }
            } compactLeading: {
                Image(systemName: iconName(attributes: context.attributes, state: context.state))
                    .foregroundStyle(context.attributes.kind.tint)
            } compactTrailing: {
                // The compact trailing region is a few points wide. Without a
                // scale factor the text is clipped rather than shrunk, and it
                // clips from the leading edge — "20%" renders as "0%", which
                // reads as a real value and not as truncation.
                Group {
                    if context.state.showsItemCount {
                        Text("\(context.state.activeItems.count)")
                            .monospacedDigit()
                    } else if let endsAt = context.state.endsAt {
                        LiveActivityCountdownText(
                            endsAt: endsAt,
                            granularity: context.state.countdownGranularity
                        )
                        .monospacedDigit()
                    } else if let value = context.state.value {
                        Text(value)
                            .font(.caption2)
                            .monospacedDigit()
                    } else if let p = context.state.progress {
                        Text("\(Int((max(0, min(p, 1)) * 100).rounded()))%")
                            .monospacedDigit()
                    } else {
                        Text(context.state.state)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            } minimal: {
                if !context.state.activeItems.isEmpty {
                    Image(systemName: iconName(attributes: context.attributes, state: context.state))
                } else if let p = context.state.progress {
                    Gauge(value: max(0, min(p, 1))) {
                        Image(systemName: iconName(attributes: context.attributes, state: context.state))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                } else {
                    Image(systemName: iconName(attributes: context.attributes, state: context.state))
                }
            }
            .widgetURL(tapURL(for: context.attributes))
        }
        // Opt the Live Activity into rendering as a Smart Stack card on Apple
        // Watch (.small) in addition to the iPhone Lock Screen (.medium).
        // LockScreenView reads \.activityFamily to pick the right layout.
        .supplementalActivityFamilies([.small, .medium])
    }

    private func iconName(
        attributes: ZeroZeroWidgetActivityAttributes,
        state: ZeroZeroWidgetActivityAttributes.ContentState
    ) -> String {
        state.icon ?? attributes.icon ?? iconName(for: attributes.kind)
    }

    /// A producer URL wins. The full app's widget target supplies an internal
    /// Activities-tab URL as its fallback; the App Clip extension deliberately
    /// omits that setting because the clip has no tab bar.
    private func tapURL(for attributes: ZeroZeroWidgetActivityAttributes) -> URL? {
        attributes.deepLink ?? ZeroZeroWidgetConstants.liveActivityFallbackURL
    }

    private func iconName(for kind: LiveActivityKind) -> String {
        switch kind {
        case .generic: return "square.dashed"
        case .progress: return "chart.bar"
        case .charging: return "bolt.car"
        case .appliance: return "washer"
        case .job: return "hammer"
        case .timer: return "timer"
        }
    }
}

private struct LockScreenView: View {
    let attributes: ZeroZeroWidgetActivityAttributes
    let state: ZeroZeroWidgetActivityAttributes.ContentState

    // .small covers every compact renderer of this activity — the Apple Watch
    // Smart Stack, and from iOS 27 the CarPlay Dashboard and the macOS menu
    // bar as well. .medium is the iPhone Lock Screen.
    @Environment(\.activityFamily) private var activityFamily

    // False when the system draws no container around this presentation. From
    // iOS 27 that is StandBy, which reuses the Lock Screen layout at 200% on a
    // charging iPhone in landscape. See `LiveActivityBackground`.
    @Environment(\.showsWidgetContainerBackground) private var showsContainerBackground

    var body: some View {
        switch activityFamily {
        case .small:
            smallBody
        default:
            lockScreenBody
        }
    }

    private var lockScreenBody: some View {
        Group {
            if state.activeItems.isEmpty {
                legacyLockScreenBody
            } else {
                compositeLockScreenBody
            }
        }
        .padding()
        .background {
            // Only inside the system's container. Enlarged edge to edge for
            // StandBy an inset wash of our own reads as stranded, so there the
            // flat activityBackgroundTint carries the surface by itself.
            if showsContainerBackground {
                LiveActivityBackground.gradient(for: attributes.kind)
            }
        }
    }

    private var compositeLockScreenBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                statusGlyph(.subheadline)
                Text(attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if state.hasExplicitValue, let value = state.value {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let unit = state.unit {
                            Text(unit)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("\(state.activeItems.count) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(state.activeItems.prefix(3))) { item in
                LiveActivityItemRow(item: item)
            }
            if state.activeItems.count > 3 {
                Text("+\(state.activeItems.count - 3) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var legacyLockScreenBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 3) {
                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    statusGlyph(.caption)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(attributes.title).font(.headline)
                    if let subtitle = state.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    if let endsAt = state.endsAt {
                        LiveActivityCountdownText(
                            endsAt: endsAt,
                            granularity: state.countdownGranularity
                        )
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                    } else if let p = state.progress, state.chart == nil {
                        ProgressView(value: max(0, min(p, 1)))
                            .progressViewStyle(.linear)
                    }
                }
                Spacer()
                // An explicit producer value is more useful than the generic
                // runtime state, even when the activity also has a deadline.
                if let value = state.value {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(value).font(.title3).fontWeight(.semibold)
                        if let unit = state.unit {
                            Text(unit).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(state.state.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.2)))
                }
            }

            // Keep the identity column clear while allowing the plot to use
            // the space beneath the trailing value/status presentation.
            if let chart = state.chart, chart.isRenderable {
                SparklineView(chart: chart, tint: attributes.kind.tint, lineWidth: 1.5)
                    .frame(height: 24)
                    .padding(.leading, 44)
            }

            Text("Updated \(state.updatedAt, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 44)
        }
    }

    /// One layout for every `.small` renderer, sized by the width it is given.
    ///
    /// Apple Watch and the CarPlay Dashboard share this family and nothing in
    /// the environment separates them, so width is the only signal available.
    /// A watch card is around 180pt across; a Dashboard cell is far wider and
    /// is read at arm's length from a driving position, where the watch's
    /// `.caption2`/`.headline` pairing is too small to be glanceable.
    private var smallBody: some View {
        GeometryReader { proxy in
            smallContent(SmallActivityMetrics.forWidth(proxy.size.width))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func smallContent(_ metrics: SmallActivityMetrics) -> some View {
        HStack(spacing: metrics.spacing) {
            Image(systemName: iconName)
                .font(metrics.icon)
                .foregroundStyle(.secondary)
            statusGlyph(metrics.statusGlyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(attributes.title)
                    .font(metrics.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !state.hasExplicitValue, let item = state.activeItems.first {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Image(systemName: item.icon ?? "circle.fill")
                            .font(metrics.caption)
                            .foregroundStyle(item.status?.tint ?? .secondary)
                        Text(item.value ?? item.title)
                            .font(metrics.value)
                            .lineLimit(1)
                        if let unit = item.unit, item.value != nil {
                            Text(unit).font(metrics.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    primarySmallValue(metrics)
                }
            }
            Spacer(minLength: 0)
            if state.showsItemCount, state.activeItems.count > 1 {
                Text("\(state.activeItems.count)")
                    .font(metrics.value)
                    .monospacedDigit()
            } else if let p = state.activeItems.first?.progress ?? state.progress,
                      state.endsAt == nil {
                Gauge(value: max(0, min(p, 1))) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .scaleEffect(metrics.gaugeScale)
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
    }

    @ViewBuilder
    private func primarySmallValue(_ metrics: SmallActivityMetrics) -> some View {
        if let endsAt = state.endsAt {
            LiveActivityCountdownText(
                endsAt: endsAt,
                granularity: state.countdownGranularity
            )
                .font(metrics.value)
                .monospacedDigit()
                .lineLimit(1)
        } else if let value = state.value {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(metrics.value).lineLimit(1)
                if let unit = state.unit {
                    Text(unit).font(metrics.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(state.state.capitalized)
                .font(metrics.state)
                .lineLimit(1)
        }
    }

    /// The runtime glyph beside the identity icon: what the activity is doing
    /// right now, as opposed to what it is.
    ///
    /// Drawn in `.primary` against the identity icon's `.secondary`, because
    /// the moving thing is the one worth the eye. Deliberately absent from the
    /// compact and minimal Dynamic Island regions — they are a few points wide,
    /// and a second glyph there would crowd out the value.
    @ViewBuilder
    private func statusGlyph(_ font: Font) -> some View {
        if let statusIcon = state.statusIcon {
            Image(systemName: statusIcon)
                .font(font)
                .foregroundStyle(attributes.kind.tint)
        }
    }

    private var iconName: String {
        if let icon = state.icon ?? attributes.icon {
            return icon
        }
        switch attributes.kind {
        case .generic: return "square.dashed"
        case .progress: return "chart.bar"
        case .charging: return "bolt.car"
        case .appliance: return "washer"
        case .job: return "hammer"
        case .timer: return "timer"
        }
    }
}

/// The ground a Live Activity is drawn on.
///
/// `activityBackgroundTint` is what StandBy shows. It reuses the Lock Screen
/// layout at 200% on a charging iPhone in landscape and draws no container of
/// its own, so the tint runs edge to edge across a bedside display — where a
/// flat 60% black filled the space with a slab carrying no identity at all.
/// The tint now mixes the activity's own accent into a dark ground the white
/// `activitySystemActionForegroundColor` stays legible against.
enum LiveActivityBackground {
    static func tint(for kind: LiveActivityKind) -> Color {
        // Mostly ground, a little accent: enough to tell a charging session
        // from a running job at a glance across a room, not enough to fight
        // the foreground.
        Color.black.mix(with: kind.tint, by: 0.16).opacity(0.72)
    }

    /// Drawn only where the system provides a container. Apple's guidance is
    /// that an inset background of our own looks stranded once StandBy
    /// enlarges it, so there this is omitted and `tint(for:)` stands alone.
    static func gradient(for kind: LiveActivityKind) -> LinearGradient {
        LinearGradient(
            colors: [kind.tint.opacity(0.16), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Type, spacing, and padding for the `.small` activity family.
///
/// Two presets rather than a continuous scale: the family renders on a small
/// number of very different surfaces, and a set of sizes each chosen to read
/// well beats interpolating between them.
private struct SmallActivityMetrics {
    var icon: Font
    var statusGlyph: Font
    var caption: Font
    var value: Font
    var state: Font
    var spacing: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var gaugeScale: CGFloat

    /// Comfortably above the widest Apple Watch Smart Stack card and below the
    /// narrowest CarPlay Dashboard cell. A container that reports no width yet
    /// falls to `tight`, which is the layout this family had before CarPlay.
    static let roomyWidthThreshold: CGFloat = 260

    static func forWidth(_ width: CGFloat) -> SmallActivityMetrics {
        width >= roomyWidthThreshold ? .roomy : .tight
    }

    static let tight = SmallActivityMetrics(
        icon: .title3,
        statusGlyph: .caption,
        caption: .caption2,
        value: .headline,
        state: .subheadline,
        spacing: 8,
        horizontalPadding: 10,
        verticalPadding: 6,
        gaugeScale: 0.8
    )

    /// Everything a step up, and the gauge at full size: this is read from a
    /// driving position rather than a raised wrist.
    static let roomy = SmallActivityMetrics(
        icon: .title2,
        statusGlyph: .subheadline,
        caption: .caption,
        value: .title3,
        state: .headline,
        spacing: 12,
        horizontalPadding: 16,
        verticalPadding: 10,
        gaugeScale: 1.0
    )
}

private struct LiveActivityItemRow: View {
    let item: LiveActivityItem
    var condensed = false

    var body: some View {
        VStack(spacing: condensed ? 2 : 3) {
            HStack(spacing: 7) {
                Image(systemName: item.icon ?? "circle.fill")
                    .font(condensed ? .caption2 : .caption)
                    .frame(width: 14)
                    .foregroundStyle(item.status?.tint ?? .secondary)
                if let statusIcon = item.statusIcon {
                    Image(systemName: statusIcon)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(condensed ? .caption2 : .caption.weight(.semibold))
                        .lineLimit(1)
                    if !condensed, let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let value = item.value {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value)
                            .font(condensed ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let unit = item.unit {
                            Text(unit)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else if let status = item.status {
                    Text(status.label)
                        .font(.caption2)
                        .foregroundStyle(status.tint)
                        .lineLimit(1)
                }
            }
            if let progress = item.progress {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(.linear)
                    .tint(item.status?.tint)
            }
        }
    }
}

private extension ZeroZeroWidgetActivityAttributes.ContentState {
    var activeItems: [LiveActivityItem] {
        (items ?? []).filter(\.isActive)
    }

    var hasExplicitValue: Bool {
        !(value ?? "").isEmpty
    }

    // The active-item count is a *derived* stand-in for a value the producer
    // did not send. A composite activity that publishes its own `value` means
    // it, so the count must never overwrite it with "2 active".
    var showsItemCount: Bool {
        !activeItems.isEmpty && !hasExplicitValue
    }
}
