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

private struct PreviewCardProvider: TimelineProvider {
    let sampleSuffix: String

    func placeholder(in context: Context) -> CardTimelineEntry { entry() }

    func getSnapshot(in context: Context, completion: @escaping (CardTimelineEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CardTimelineEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> CardTimelineEntry {
        let id = SampleDataFactory.sampleId(sampleSuffix)
        let card = CardCache.load().cards.first(where: { $0.id == id })
            ?? SampleDataFactory.makeMarketingPreviewCards(
                referenceDate: ZeroZeroWidgetDateFormat.parse("2026-09-01T09:41:00Z")!
            ).first(where: { $0.id == id })
        return CardTimelineEntry(date: Date(), card: card, density: .compact)
    }
}

private struct ScreenshotMetricsGridProvider: TimelineProvider {
    private let sampleSuffixes = ["trials", "support", "agent-runs", "ai-spend"]

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

private func previewCardConfiguration(
    kind: String,
    sampleSuffix: String,
    displayName: String,
    supportedFamilies: [WidgetFamily] = [.systemSmall]
) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: PreviewCardProvider(sampleSuffix: sampleSuffix)) { entry in
        CardWidgetView(entry: entry)
            .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName(displayName)
    .description("App Store Preview fixture.")
    .supportedFamilies(supportedFamilies)
}

struct PreviewCountdownWidget: Widget {
    var body: some WidgetConfiguration {
        previewCardConfiguration(
            kind: "com.00widget.preview.countdown",
            sampleSuffix: "preview-countdown",
            displayName: "Preview Countdown"
        )
    }
}

struct PreviewMarsWidget: Widget {
    var body: some WidgetConfiguration {
        previewCardConfiguration(
            kind: "com.00widget.preview.mars",
            sampleSuffix: "preview-mars",
            displayName: "Preview Mars",
            supportedFamilies: [.systemSmall, .systemMedium]
        )
    }
}

struct PreviewWeekendWidget: Widget {
    var body: some WidgetConfiguration {
        previewCardConfiguration(
            kind: "com.00widget.preview.weekend",
            sampleSuffix: "preview-weekend",
            displayName: "Preview Weekend",
            supportedFamilies: [.systemSmall, .systemMedium]
        )
    }
}

struct ScreenshotProductionWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.production",
            sampleSuffix: "production",
            displayName: "Screenshot Production"
        )
    }
}

struct ScreenshotOpenPRsWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.open-prs",
            sampleSuffix: "open-prs",
            displayName: "Screenshot Open PRs"
        )
    }
}

struct ScreenshotLaunchMessageWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.launch-message",
            sampleSuffix: "launch-message",
            displayName: "Screenshot Launch Message"
        )
    }
}

struct ScreenshotTrialsLargeWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.trials-large",
            sampleSuffix: "trials",
            displayName: "Screenshot Trials Large",
            density: .automatic,
            supportedFamilies: [.systemLarge]
        )
    }
}

struct ScreenshotTrialsWideWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.trials-wide",
            sampleSuffix: "trials",
            displayName: "Screenshot Trials Wide",
            density: .automatic,
            supportedFamilies: [.systemMedium]
        )
    }
}

struct ScreenshotAgentRunsWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.agent-runs",
            sampleSuffix: "agent-runs",
            displayName: "Screenshot Agent Runs"
        )
    }
}

struct ScreenshotSupportWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.support",
            sampleSuffix: "support",
            displayName: "Screenshot Support"
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
