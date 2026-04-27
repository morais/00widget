import SwiftUI
import AppIntents

public enum CardRenderContext {
    case app
    case widgetSmall
    case widgetMedium
    case widgetLarge
    case accessoryRectangular
    case accessoryCircular
    case accessoryInline
}

public struct CardView: View {
    public let card: DashboardCard
    public let context: CardRenderContext

    public init(card: DashboardCard, context: CardRenderContext = .app) {
        self.card = card
        self.context = context
    }

    public var body: some View {
        switch context {
        case .accessoryInline:
            inlineView
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        case .widgetSmall:
            smallView
        case .widgetMedium:
            mediumView
        case .widgetLarge:
            largeView
        case .app:
            appView
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = card.icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(card.status.tint)
            }
            Text(card.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 0)
            StatusBadge(status: card.status, compact: true)
        }
    }

    private var bigValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(card.value ?? "—")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let unit = card.unit {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            switch card.template {
            case .progress:
                if let p = Double(card.value ?? "") ?? card.progressValue {
                    ProgressRow(progress: p, label: card.subtitle)
                } else {
                    bigValue
                }
            case .action:
                actionSummary
                actionButtons(max: 1)
            case .list:
                listRows(max: 3)
            default:
                bigValue
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            switch card.template {
            case .list:
                listRows(max: 3)
            case .action:
                actionSummary
                actionButtons(max: 2)
            case .progress:
                if let p = card.progressValue {
                    ProgressRow(progress: p, label: card.subtitle)
                }
                bigValue
            default:
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        bigValue
                        if let subtitle = card.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            Spacer(minLength: 0)
            Text(card.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch card.template {
            case .list:
                listRows(max: 6)
            case .action:
                actionSummary
                actionButtons(max: 4)
            default:
                bigValue
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let p = card.progressValue {
                    ProgressRow(progress: p, label: nil)
                }
            }
            Spacer(minLength: 0)
            Text("Updated \(card.updatedAt, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let icon = card.icon { Image(systemName: icon) }
                Text(card.title).font(.caption2).fontWeight(.medium)
            }
            Text(card.value ?? card.status.label)
                .font(.headline)
            if let subtitle = card.subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var circularView: some View {
        Gauge(value: card.progressValue ?? 0) {
            if let icon = card.icon { Image(systemName: icon) }
        } currentValueLabel: {
            Text(card.value ?? "—").font(.caption).lineLimit(1)
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var inlineView: some View {
        HStack(spacing: 4) {
            if let icon = card.icon { Image(systemName: icon) }
            Text("\(card.title): \(card.value ?? card.status.label)\(card.unit.map { " \($0)" } ?? "")")
        }
    }

    private var appView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch card.template {
            case .list:
                listRows(max: 10)
            case .progress:
                if let p = card.progressValue {
                    ProgressRow(progress: p, label: card.subtitle)
                }
                bigValue
            default:
                bigValue
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let actions = card.actions, !actions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Actions").font(.caption).foregroundStyle(.secondary)
                    ForEach(actions) { action in
                        Text(action.label)
                            .font(.callout)
                    }
                }
            }
            Text("Updated \(card.updatedAt.formatted(.dateTime))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var actionSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            bigValue
            if let subtitle = card.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func listRows(max: Int) -> some View {
        if let items = card.items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.prefix(max)) { item in
                    HStack {
                        Text(item.title).font(.caption).lineLimit(1)
                        Spacer()
                        if let v = item.value {
                            Text("\(v)\(item.unit ?? "")")
                                .font(.caption)
                                .foregroundStyle(item.status?.tint ?? .primary)
                        }
                    }
                }
            }
        } else {
            Text("No items").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actionButtons(max: Int) -> some View {
        if let actions = card.actions, !actions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(actions.prefix(max)) { action in
                    if action.isSafeFromWidget {
                        Button(intent: RunDashboardActionIntent(actionId: action.id, cardId: card.id)) {
                            Text(action.label)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if let deepLink = card.deepLink {
                        Link(destination: deepLink) {
                            Text(action.label)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

extension DashboardCard {
    var progressValue: Double? {
        if template == .progress, let v = value, let d = Double(v) {
            return d > 1 ? d / 100 : d
        }
        return nil
    }
}

public struct CardFallbackView: View {
    public enum Reason {
        case noCardSelected
        case noCachedData
        case stale(Date)
        case error(String)
    }

    public let reason: Reason
    public init(reason: Reason) { self.reason = reason }

    public var body: some View {
        VStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center) }
        }
        .padding(8)
    }

    private var iconName: String {
        switch reason {
        case .noCardSelected: return "square.dashed"
        case .noCachedData: return "icloud.slash"
        case .stale: return "clock.badge.exclamationmark"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch reason {
        case .noCardSelected: return "Pick a card"
        case .noCachedData: return "No data"
        case .stale: return "Stale"
        case .error: return "Error"
        }
    }

    private var detail: String? {
        switch reason {
        case .noCardSelected: return "Long-press to configure."
        case .noCachedData: return "Open 00Widget and refresh."
        case .stale(let d): return "Updated \(d.formatted(.relative(presentation: .named)))"
        case .error(let m): return m
        }
    }
}
