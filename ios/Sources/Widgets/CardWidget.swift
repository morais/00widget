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
        .supportedFamilies(FullPageWidgetFamily.adding(to: [
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline
        ]))
        .pushHandler(ZeroZeroWidgetPushHandler.self)
    }
}

struct CardWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: CardTimelineEntry

    var body: some View {
        content
            // Home Screen families only. The Lock Screen accessories are a
            // handful of points tall and monochrome by design, so a badge there
            // would displace the content it is meant to annotate.
            .widgetUpdateStamp(isSystemFamily ? entry.updateMark : nil)
            .widgetURL(entry.card?.deepLink)
    }

    private var isSystemFamily: Bool {
        if FullPageWidgetFamily.contains(family) { return true }
        switch family {
        case .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        if let card = entry.card {
            CardView(card: card, context: contextFor(family: family), density: entry.density)
        } else {
            CardFallbackView(reason: entry.reason ?? .noCachedData)
        }
    }

    private func contextFor(family: WidgetFamily) -> CardRenderContext {
        switch family {
        case .systemSmall: return .widgetSmall
        case .systemMedium: return .widgetMedium
        case .systemLarge: return .widgetLarge
        case .systemExtraLarge: return .widgetExtraLarge
        case .accessoryRectangular: return .accessoryRectangular
        case .accessoryCircular: return .accessoryCircular
        case .accessoryInline: return .accessoryInline
        // WidgetFamily is not frozen, so this branch is where every family
        // Apple adds arrives first. New families have consistently been
        // *bigger* canvases, never smaller ones, so degrade to the roomiest
        // layout. This used to return .widgetSmall, which meant a full-page
        // widget would have rendered the small layout with nothing to indicate
        // it. iOS 27's `systemExtraLargePortrait` is opted into deliberately
        // (see FullPageWidgetFamily) and lands here on purpose rather than by
        // omission — it wants .widgetExtraLarge too.
        default: return .widgetExtraLarge
        }
    }
}
