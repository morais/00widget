#if ZW_SCREENSHOTS
import SwiftUI
import WidgetKit

/// Fixed sample widgets used only by the marketing screenshot build.
///
/// The Simulator does not rehydrate AppIntent entity selections, so three
/// configurable small CardWidget instances cannot retain three distinct cards.
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

struct ScreenshotEnergyWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.energy",
            sampleSuffix: "energy-trend",
            displayName: "Screenshot Energy"
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
#endif
