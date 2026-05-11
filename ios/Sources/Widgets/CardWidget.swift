import WidgetKit
import SwiftUI

struct CardWidget: Widget {
    let kind: String = ZeroZeroWidgetConstants.WidgetKinds.card

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectCardIntent.self,
            provider: CardTimelineProvider()
        ) { entry in
            CardWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("00Widget Card")
        .description("Show one 00Widget card.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline
        ])
        .pushHandler(ZeroZeroWidgetPushHandler.self)
    }
}

struct CardWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: CardTimelineEntry

    var body: some View {
        content
            .widgetURL(entry.card?.deepLink)
    }

    @ViewBuilder
    private var content: some View {
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
