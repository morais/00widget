import WidgetKit
import SwiftUI

struct StatusWidget: Widget {
    let kind: String = "ZeroZeroWidgetStatusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectCardIntent.self,
            provider: CardTimelineProvider()
        ) { entry in
            MetricWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Status")
        .description("Show the status of a 00Widget card.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryRectangular, .accessoryCircular, .accessoryInline
        ])
    }
}
