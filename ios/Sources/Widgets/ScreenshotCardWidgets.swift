#if ZW_SCREENSHOTS
import SwiftUI
import WidgetKit

/// Fixed sample widgets used only by the marketing screenshot build.
///
/// The Simulator does not rehydrate AppIntent entity selections, so multiple
/// configurable CardWidget instances cannot retain distinct cards.
/// These static configurations exercise the same production renderer while
/// giving the screenshot harness stable, independently identifiable widgets.
private struct ScreenshotCardProvider: TimelineProvider {
    let sampleSuffix: String
    let density: CardRenderDensity

    func placeholder(in context: Context) -> CardTimelineEntry {
        entry()
    }

    func getSnapshot(in context: Context, completion: @escaping (CardTimelineEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CardTimelineEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> CardTimelineEntry {
        let id = SampleDataFactory.sampleId(sampleSuffix)
        let card = CardCache.load().cards.first(where: { $0.id == id })
            ?? SampleDataFactory.makeCards().first(where: { $0.id == id })
        return CardTimelineEntry(date: Date(), card: card, density: density)
    }
}

private struct ScreenshotMetricsGridProvider: TimelineProvider {
    private let sampleSuffixes = ["solar", "car-charge", "energy-trend", "deploys"]

    func placeholder(in context: Context) -> CardGridEntry {
        entry()
    }

    func getSnapshot(in context: Context, completion: @escaping (CardGridEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CardGridEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> CardGridEntry {
        let cached = CardCache.load().cards
        let samples = SampleDataFactory.makeCards()
        let cards = sampleSuffixes.compactMap { suffix in
            let id = SampleDataFactory.sampleId(suffix)
            return cached.first(where: { $0.id == id })
                ?? samples.first(where: { $0.id == id })
        }
        return CardGridEntry(
            date: Date(),
            cards: cards,
            compactTapTarget: .app,
            density: .automatic,
            statusFilter: .all
        )
    }
}

private func screenshotCardConfiguration(
    kind: String,
    sampleSuffix: String,
    displayName: String,
    density: CardRenderDensity = .compact,
    supportedFamilies: [WidgetFamily] = [.systemSmall]
) -> some WidgetConfiguration {
    StaticConfiguration(
        kind: kind,
        provider: ScreenshotCardProvider(sampleSuffix: sampleSuffix, density: density)
    ) { entry in
        CardWidgetView(entry: entry)
            .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName(displayName)
    .description("Marketing screenshot sample.")
    .supportedFamilies(supportedFamilies)
}

struct ScreenshotSolarWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.solar",
            sampleSuffix: "solar",
            displayName: "Screenshot Solar"
        )
    }
}

struct ScreenshotWasherWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.washer",
            sampleSuffix: "washer",
            displayName: "Screenshot Washer"
        )
    }
}

struct ScreenshotBoilerWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.boiler",
            sampleSuffix: "boiler",
            displayName: "Screenshot Boiler"
        )
    }
}

struct ScreenshotEnergyLargeWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.energy-large",
            sampleSuffix: "energy-trend",
            displayName: "Screenshot Energy Large",
            density: .automatic,
            supportedFamilies: [.systemLarge]
        )
    }
}

struct ScreenshotEnergyWideWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.energy-wide",
            sampleSuffix: "energy-trend",
            displayName: "Screenshot Energy Wide",
            density: .automatic,
            supportedFamilies: [.systemMedium]
        )
    }
}

struct ScreenshotDeploysWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.deploys",
            sampleSuffix: "deploys",
            displayName: "Screenshot Deploys"
        )
    }
}

struct ScreenshotDeviceFleetWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.device-fleet",
            sampleSuffix: "device-fleet",
            displayName: "Screenshot Device Fleet"
        )
    }
}

struct ScreenshotMetricsLargeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.00widget.screenshot.metrics-large",
            provider: ScreenshotMetricsGridProvider()
        ) { entry in
            CardGridWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Screenshot Four Metrics Large")
        .description("Marketing screenshot sample.")
        .supportedFamilies([.systemLarge])
    }
}

struct ScreenshotMetricsExtraLargeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.00widget.screenshot.metrics-extra-large",
            provider: ScreenshotMetricsGridProvider()
        ) { entry in
            CardGridWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Screenshot Four Metrics Extra Large")
        .description("Marketing screenshot sample.")
        .supportedFamilies([.systemExtraLarge])
    }
}
#endif
