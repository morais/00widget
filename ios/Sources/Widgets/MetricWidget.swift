import WidgetKit
import SwiftUI

struct MetricWidget: Widget {
    let kind: String = "ZeroZeroWidgetMetricWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectCardIntent.self,
            provider: CardTimelineProvider()
        ) { entry in
            MetricWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Metric")
        .description("Show a single metric from a 00Widget card.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline
        ])
        // Future: WidgetConfiguration.pushHandler (iOS 18+) for sub-15-minute
        // server-driven reloads. Backend already accepts the token at
        // /v1/widgets/register-push-token; iOS-side observation isn't wired yet.
        // Until then, timeline refreshes (every 15min) are the update path.
    }
}

struct MetricWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: CardTimelineEntry

    var body: some View {
        if let card = entry.card {
            CardView(card: card, context: contextFor(family: family))
        } else {
            CardFallbackView(reason: entry.reason ?? .noCachedData)
        }
    }

    private func contextFor(family: WidgetFamily) -> CardRenderContext {
        switch family {
        case .systemSmall: return .widgetSmall
        case .systemMedium: return .widgetMedium
        case .systemLarge: return .widgetLarge
        case .accessoryRectangular: return .accessoryRectangular
        case .accessoryCircular: return .accessoryCircular
        case .accessoryInline: return .accessoryInline
        default: return .widgetSmall
        }
    }
}
