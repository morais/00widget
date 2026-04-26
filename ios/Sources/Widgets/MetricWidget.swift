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
        // To enable WidgetKit push: bump deployment target to iOS 26.0, then
        // (a) add a struct conforming to WidgetPushHandler that calls
        //     WidgetPushTokenStore.record(widgetKind:pushToken:) for each
        //     token it receives, and (b) append .pushHandler(YourHandler.self)
        // here. The backend (sendWidgetReloadPush) and the App-Group token
        // bridge (WidgetPushTokenStore + AppEnvironment.registerPendingWidget-
        // Tokens) are already in place — only the call site is SDK-gated.
        // The iOS 18 fallback is timeline refresh every 15 minutes.
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
