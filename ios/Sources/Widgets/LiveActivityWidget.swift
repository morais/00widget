import WidgetKit
import SwiftUI
import ActivityKit

struct ZeroZeroWidgetLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ZeroZeroWidgetActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.title, systemImage: iconName(attributes: context.attributes, state: context.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let endsAt = context.state.endsAt {
                        LiveActivityCountdownText(
                            endsAt: endsAt,
                            granularity: context.state.countdownGranularity
                        )
                            .font(.headline)
                            .monospacedDigit()
                            .lineLimit(1)
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
                DynamicIslandExpandedRegion(.center) {
                    if let subtitle = context.state.subtitle {
                        Text(subtitle).font(.caption)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let p = context.state.progress, context.state.endsAt == nil {
                        ProgressView(value: max(0, min(p, 1)))
                            .progressViewStyle(.linear)
                    }
                }
            } compactLeading: {
                Image(systemName: iconName(attributes: context.attributes, state: context.state))
            } compactTrailing: {
                // The compact trailing region is a few points wide. Without a
                // scale factor the text is clipped rather than shrunk, and it
                // clips from the leading edge — "20%" renders as "0%", which
                // reads as a real value and not as truncation.
                Group {
                    if let endsAt = context.state.endsAt {
                        LiveActivityCountdownText(
                            endsAt: endsAt,
                            granularity: context.state.countdownGranularity
                        )
                        .monospacedDigit()
                    } else if let value = context.state.value {
                        Text(value)
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
                if let p = context.state.progress {
                    Gauge(value: max(0, min(p, 1))) {
                        Image(systemName: iconName(attributes: context.attributes, state: context.state))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                } else {
                    Image(systemName: iconName(attributes: context.attributes, state: context.state))
                }
            }
            .widgetURL(context.attributes.deepLink)
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

    // .small is Apple Watch Smart Stack; .medium is iPhone Lock Screen. The
    // watch surface is much narrower and shorter, so it gets a tighter layout.
    @Environment(\.activityFamily) private var activityFamily

    var body: some View {
        switch activityFamily {
        case .small:
            watchBody
        default:
            lockScreenBody
        }
    }

    private var lockScreenBody: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.secondary)
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
                } else if let p = state.progress {
                    ProgressView(value: max(0, min(p, 1)))
                        .progressViewStyle(.linear)
                }
                Text("Updated \(state.updatedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if state.endsAt != nil {
                Text(state.state.capitalized)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            } else if let value = state.value {
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
        .padding()
    }

    private var watchBody: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attributes.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                primaryWatchValue
            }
            Spacer(minLength: 0)
            if let p = state.progress, state.endsAt == nil {
                Gauge(value: max(0, min(p, 1))) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var primaryWatchValue: some View {
        if let endsAt = state.endsAt {
            LiveActivityCountdownText(
                endsAt: endsAt,
                granularity: state.countdownGranularity
            )
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
        } else if let value = state.value {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.headline).lineLimit(1)
                if let unit = state.unit {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(state.state.capitalized)
                .font(.subheadline)
                .lineLimit(1)
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
