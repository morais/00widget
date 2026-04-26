import WidgetKit
import SwiftUI

struct ProgressWidget: Widget {
    let kind: String = "ZeroZeroWidgetProgressWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectCardIntent.self,
            provider: CardTimelineProvider()
        ) { entry in
            MetricWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Progress")
        .description("Show a progress bar from a 00Widget card.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular
        ])
    }
}
