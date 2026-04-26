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
                    Label(context.attributes.title, systemImage: iconName(for: context.attributes.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let value = context.state.value {
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
                    if let p = context.state.progress {
                        ProgressView(value: max(0, min(p, 1)))
                            .progressViewStyle(.linear)
                    }
                }
            } compactLeading: {
                Image(systemName: iconName(for: context.attributes.kind))
            } compactTrailing: {
                if let value = context.state.value {
                    Text(value)
                } else if let p = context.state.progress {
                    Text("\(Int(p * 100))%")
                } else {
                    Text(context.state.state)
                }
            } minimal: {
                if let p = context.state.progress {
                    Gauge(value: max(0, min(p, 1))) {
                        Image(systemName: iconName(for: context.attributes.kind))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                } else {
                    Image(systemName: iconName(for: context.attributes.kind))
                }
            }
            .widgetURL(context.attributes.deepLink)
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(attributes.title).font(.headline)
                if let subtitle = state.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if let p = state.progress {
                    ProgressView(value: max(0, min(p, 1)))
                        .progressViewStyle(.linear)
                }
                Text("Updated \(state.updatedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
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
        .padding()
    }

    private var iconName: String {
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
