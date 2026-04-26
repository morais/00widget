import WidgetKit
import SwiftUI

struct ListWidget: Widget {
    let kind: String = "ZeroZeroWidgetListWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectCardIntent.self,
            provider: CardTimelineProvider()
        ) { entry in
            ListWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("List")
        .description("Show the list of items of a 00Widget card.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ListWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: CardTimelineEntry

    var body: some View {
        if let card = entry.card {
            CardView(card: card, context: family == .systemLarge ? .widgetLarge : .widgetMedium)
        } else {
            CardFallbackView(reason: entry.reason ?? .noCachedData)
        }
    }
}
