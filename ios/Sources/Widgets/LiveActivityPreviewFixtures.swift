#if targetEnvironment(simulator)
import Foundation

/// One canonical state used by both Xcode's native ActivityKit previews and
/// the batch `ImageRenderer` gallery. Keeping the inputs in one place is what
/// makes a layout review cheap: a new rendering branch adds one fixture and is
/// then visible in every preview surface.
struct LiveActivityPreviewFixture: Identifiable {
    let id: String
    let name: String
    let attributes: ZeroZeroWidgetActivityAttributes
    let state: ZeroZeroWidgetActivityAttributes.ContentState
    let systemIsStale: Bool

    init(
        id: String,
        name: String,
        session: LiveActivitySession,
        systemIsStale: Bool = false
    ) {
        self.id = id
        self.name = name
        (attributes, state) = ZeroZeroWidgetActivityAttributes.from(session)
        self.systemIsStale = systemIsStale
    }
}

enum LiveActivityPreviewFixtures {
    private static let now = Date()
    private static let recently = now.addingTimeInterval(-225)

    private static func session(
        id: String,
        kind: LiveActivityKind = .generic,
        title: String,
        subtitle: String? = nil,
        state: String,
        signal: MetricSignal? = nil,
        icon: String? = nil,
        statusIcon: String? = nil,
        value: String? = nil,
        unit: String? = nil,
        progress: Double? = nil,
        items: [LiveActivityItem]? = nil,
        chart: DashboardChart? = nil,
        endsAt: Date? = nil,
        staleAt: Date? = nil
    ) -> LiveActivitySession {
        LiveActivitySession(
            externalActivityId: "preview-\(id)",
            kind: kind,
            title: title,
            subtitle: subtitle,
            state: state,
            signal: signal,
            icon: icon,
            statusIcon: statusIcon,
            value: value,
            unit: unit,
            progress: progress,
            items: items,
            chart: chart,
            endsAt: endsAt,
            countdownGranularity: endsAt == nil ? nil : .minute,
            startedAt: now.addingTimeInterval(-1_800),
            updatedAt: recently,
            staleAt: staleAt
        )
    }

    static let text = LiveActivityPreviewFixture(
        id: "text",
        name: "Text state",
        session: session(
            id: "text", title: "Garden irrigation", subtitle: "North beds",
            state: "Watering", signal: .favorable, icon: "drop.fill"
        )
    )

    static let value = LiveActivityPreviewFixture(
        id: "value",
        name: "Value and unit",
        session: session(
            id: "value", kind: .appliance, title: "Solar surplus",
            subtitle: "Water heater · Heating to 80°C", state: "Heating",
            signal: .neutral, icon: "sun.max.fill", statusIcon: "flame.fill",
            value: "58", unit: "°C", progress: 0.72
        )
    )

    static let countdown = LiveActivityPreviewFixture(
        id: "countdown",
        name: "Countdown",
        session: session(
            id: "countdown", kind: .timer, title: "Dinner timer",
            subtitle: "Roast vegetables", state: "Cooking", icon: "timer",
            endsAt: now.addingTimeInterval(2_760)
        )
    )

    static let progress = LiveActivityPreviewFixture(
        id: "progress",
        name: "Progress",
        session: session(
            id: "progress", kind: .job, title: "Deploying website",
            subtitle: "Uploading release assets", state: "Running",
            icon: "arrow.up.circle.fill", value: "3/5", progress: 0.6
        )
    )

    static let countdownProgress = LiveActivityPreviewFixture(
        id: "countdown-progress",
        name: "Countdown and progress",
        session: session(
            id: "countdown-progress", kind: .appliance, title: "Laundry",
            subtitle: "Cottons · 40°C", state: "Washing", icon: "washer",
            value: "2/4", progress: 0.5, endsAt: now.addingTimeInterval(1_440)
        )
    )

    static let finished = LiveActivityPreviewFixture(
        id: "finished",
        name: "Finished",
        session: session(
            id: "finished", kind: .job, title: "Backup complete",
            subtitle: "42.8 GB copied", state: "Finished", signal: .favorable,
            icon: "externaldrive.fill.badge.checkmark", value: "100", unit: "%", progress: 1
        )
    )

    static let line = LiveActivityPreviewFixture(
        id: "chart-line",
        name: "Line chart",
        session: session(
            id: "chart-line", kind: .charging, title: "Home battery topping up",
            subtitle: "PV 3.9kW · Battery +537W", state: "Charging",
            signal: .favorable, icon: "battery.100percent.bolt",
            value: "93", unit: "%", chart: DashboardChart(
                points: [54, 61, 66, 73, 78, 84, 88, 91, 93], min: 0, max: 100,
                reference: 95, semantic: MetricSemantic(role: .actual, flow: .inbound, signal: .favorable)
            )
        )
    )

    static let bar = LiveActivityPreviewFixture(
        id: "chart-bar",
        name: "Bar chart",
        session: session(
            id: "chart-bar", title: "Requests this hour", subtitle: "Per five minutes",
            state: "Healthy", signal: .favorable, icon: "chart.bar.fill",
            value: "1.8k", chart: DashboardChart(
                points: [4, 8, 5, 12, 9, 16, 13, 18], min: 0, max: 20, style: .bar
            )
        )
    )

    static let delta = LiveActivityPreviewFixture(
        id: "chart-delta",
        name: "Delta chart",
        session: session(
            id: "chart-delta", title: "Grid flow", subtitle: "Import and export",
            state: "Exporting", signal: .favorable, icon: "arrow.left.arrow.right",
            value: "+537", unit: "W", chart: DashboardChart(
                points: [-3, 4, 7, -2, 8, 3, -5, 6], min: -10, max: 10,
                semantic: MetricSemantic(role: .actual, flow: .outbound, signal: .favorable),
                style: .delta
            )
        )
    )

    static let range = LiveActivityPreviewFixture(
        id: "chart-range",
        name: "Range chart",
        session: session(
            id: "chart-range", title: "Delivery window", subtitle: "Forecast confidence",
            state: "On schedule", signal: .neutral, icon: "truck.box.fill",
            value: "15:20", chart: DashboardChart(
                points: [], min: 0, max: 60, style: .range, rangeValueLabel: "Expected",
                ranges: [
                    .init(low: 8, high: 28, value: 16), .init(low: 12, high: 35, value: 22),
                    .init(low: 17, high: 42, value: 29), .init(low: 20, high: 49, value: 34),
                    .init(low: 26, high: 54, value: 40)
                ]
            )
        )
    )

    static let stacked = LiveActivityPreviewFixture(
        id: "chart-stacked",
        name: "Stacked bars",
        session: session(
            id: "chart-stacked", title: "Energy mix", subtitle: "Solar + grid",
            state: "Supplying home", signal: .favorable, icon: "bolt.house.fill",
            value: "4.4", unit: "kW", chart: DashboardChart(
                points: [], min: 0, max: 6, style: .bar,
                series: [
                    .init(id: "solar", label: "Solar", points: [2.1, 2.7, 3.2, 3.7, 3.9], semantic: .init(flow: .inbound, signal: .favorable)),
                    .init(id: "grid", label: "Grid", points: [1.4, 1.0, 0.8, 0.5, 0.5], semantic: .init(flow: .inbound, signal: .neutral))
                ], stacking: .stacked
            )
        )
    )

    static let grouped = LiveActivityPreviewFixture(
        id: "chart-grouped",
        name: "Grouped bars",
        session: session(
            id: "chart-grouped", title: "Build comparison", subtitle: "Current vs baseline",
            state: "Testing", signal: .neutral, icon: "hammer.fill", value: "42", unit: "s",
            chart: DashboardChart(
                points: [], min: 0, max: 60, style: .bar,
                series: [
                    .init(id: "current", label: "Current", points: [48, 44, 42, 39], semantic: .init(role: .actual)),
                    .init(id: "baseline", label: "Baseline", points: [52, 51, 50, 49], semantic: .init(role: .baseline))
                ], stacking: .grouped
            )
        )
    )

    static let countdownChart = LiveActivityPreviewFixture(
        id: "countdown-chart",
        name: "Countdown and chart",
        session: session(
            id: "countdown-chart", kind: .charging, title: "EV charging",
            subtitle: "Home charger · 7.2kW", state: "Charging", signal: .favorable,
            icon: "bolt.car.fill", progress: 0.68,
            chart: DashboardChart(points: [22, 29, 35, 43, 50, 58, 64, 68], min: 0, max: 100),
            endsAt: now.addingTimeInterval(3_840)
        )
    )

    private static let jobItems: [LiveActivityItem] = [
        .init(id: "build", title: "Build", icon: "hammer.fill", value: "Done", status: .finished),
        .init(id: "tests", title: "Tests", subtitle: "412 passed", icon: "checkmark.seal.fill", progress: 1, status: .finished),
        .init(id: "upload", title: "Upload", subtitle: "TestFlight", icon: "arrow.up.circle.fill", value: "68", unit: "%", progress: 0.68, status: .running),
        .init(id: "review", title: "Processing", icon: "clock.fill", status: .paused)
    ]

    static let items = LiveActivityPreviewFixture(
        id: "items",
        name: "Item rows",
        session: session(
            id: "items", kind: .job, title: "Shipping release", state: "Uploading",
            icon: "shippingbox.fill", value: "2/4", progress: 0.5,
            items: Array(jobItems.prefix(3))
        )
    )

    static let overflow = LiveActivityPreviewFixture(
        id: "items-overflow",
        name: "Items with overflow",
        session: session(
            id: "items-overflow", kind: .job, title: "Shipping release", state: "Uploading",
            icon: "shippingbox.fill", value: "2/4", progress: 0.5, items: jobItems
        )
    )

    static let stale = LiveActivityPreviewFixture(
        id: "stale",
        name: "Stale",
        session: session(
            id: "stale", kind: .charging, title: "Garage charger",
            subtitle: "Last reading is no longer current", state: "Charging",
            signal: .caution, icon: "bolt.car.fill", value: "41", unit: "%",
            progress: 0.41, staleAt: now.addingTimeInterval(-60)
        ),
        systemIsStale: true
    )

    // Compact-only states. The visible Lock Screen shapes above already cover
    // these inputs, but compact branch order is deliberate: any honest
    // fraction becomes a ring before count or token can be considered.
    static let compactCount = LiveActivityPreviewFixture(
        id: "compact-count",
        name: "Compact item count",
        session: session(
            id: "compact-count", kind: .job, title: "Parallel checks", state: "Running",
            icon: "checklist", items: [
                .init(id: "api", title: "API", status: .running),
                .init(id: "ios", title: "iOS", status: .paused)
            ]
        )
    )

    static let compactToken = LiveActivityPreviewFixture(
        id: "compact-token",
        name: "Compact value token",
        session: session(
            id: "compact-token", title: "Service health", state: "Healthy",
            signal: .favorable, icon: "heart.fill", value: "OK"
        )
    )

    static let all: [LiveActivityPreviewFixture] = [
        text, value, countdown, progress, countdownProgress, finished,
        line, bar, delta, range, stacked, grouped, countdownChart,
        items, overflow, stale
    ]
}
#endif
