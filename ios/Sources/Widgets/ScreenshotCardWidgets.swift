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

/// Static preview widgets for the App Store Preview timeline. They render the
/// deterministic launch-story hero -- small Launch, Production and Open PRs
/// plus the wide Trials chart -- through the production card renderer.
private struct PreviewCardProvider: TimelineProvider {
    let sampleSuffix: String
    let density: CardRenderDensity

    func placeholder(in context: Context) -> CardTimelineEntry { entry() }

    func getSnapshot(in context: Context, completion: @escaping (CardTimelineEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CardTimelineEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> CardTimelineEntry {
        let id = SampleDataFactory.sampleId(sampleSuffix)
        let referenceDate = ZeroZeroWidgetDateFormat.parse("2026-09-01T09:41:00Z")!
        let card = CardCache.load().cards.first(where: { $0.id == id })
            ?? SampleDataFactory.makePreviewLaunchCards(referenceDate: referenceDate)
                .first(where: { $0.id == id })
        return CardTimelineEntry(date: Date(), card: card, density: density)
    }
}

private struct ScreenshotMetricsGridProvider: TimelineProvider {
    private let sampleSuffixes = SampleDataFactory.marketingGridCardSuffixes

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
    density: CardRenderDensity = .compact,
    supportedFamilies: [WidgetFamily] = [.systemSmall]
) -> some WidgetConfiguration {
    StaticConfiguration(
        kind: kind,
        provider: PreviewCardProvider(sampleSuffix: sampleSuffix, density: density)
    ) { entry in
        CardWidgetView(entry: entry)
            .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName(displayName)
    .description("App Store Preview fixture.")
    .supportedFamilies(supportedFamilies)
}

struct PreviewLaunchWidget: Widget {
    var body: some WidgetConfiguration {
        previewCardConfiguration(
            kind: ZeroZeroWidgetConstants.PreviewWidgetKinds.launch,
            sampleSuffix: "preview-launch",
            displayName: "Preview Launch"
        )
    }
}

struct PreviewProductionWidget: Widget {
    var body: some WidgetConfiguration {
        previewCardConfiguration(
            kind: ZeroZeroWidgetConstants.PreviewWidgetKinds.production,
            sampleSuffix: "preview-production",
            displayName: "Preview Production"
        )
    }
}

struct PreviewOpenPRsWidget: Widget {
    var body: some WidgetConfiguration {
        previewCardConfiguration(
            kind: ZeroZeroWidgetConstants.PreviewWidgetKinds.openPRs,
            sampleSuffix: "preview-open-prs",
            displayName: "Preview Open PRs"
        )
    }
}

struct PreviewTrialsWideWidget: Widget {
    var body: some WidgetConfiguration {
        previewCardConfiguration(
            kind: ZeroZeroWidgetConstants.PreviewWidgetKinds.trialsWide,
            sampleSuffix: "preview-trials",
            displayName: "Preview Trials Wide",
            density: .automatic,
            supportedFamilies: [.systemMedium]
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

struct ScreenshotLaunchWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.launch",
            sampleSuffix: "launch",
            displayName: "Screenshot Launch"
        )
    }
}

// The Lock Screen's accessory row, as the campaign defines it: two
// rectangular widgets below the clock and nothing else.
//
// Two, not four. A rectangular takes two of the four slot-widths, so this
// fills the row exactly — and the row is deliberately not a demonstration of
// every renderer. Launch is *not* here: its Live Activity sits directly below,
// and putting the same task in both recreates the repetition that got the
// expanded-Island composite rejected. The inline slot above the clock keeps
// the date, because replacing a familiar system element is a bigger ask of the
// viewer than the campaign needs.
//
// Rectangular is also the accessory that earns its space here: it draws the
// title, the value and then a sparkline or status strip, so Trials shows a
// trend and Agent runs shows twenty outcomes, where a circular would show one
// number in a ring.
struct ScreenshotTrialsRectangularWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.trials-rectangular",
            sampleSuffix: "trials",
            displayName: "Screenshot Trials Lock",
            density: .automatic,
            supportedFamilies: [.accessoryRectangular]
        )
    }
}

struct ScreenshotAgentRunsRectangularWidget: Widget {
    var body: some WidgetConfiguration {
        screenshotCardConfiguration(
            kind: "com.00widget.screenshot.agent-runs-rectangular",
            sampleSuffix: "agent-runs",
            displayName: "Screenshot Agent Runs Lock",
            density: .automatic,
            supportedFamilies: [.accessoryRectangular]
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
