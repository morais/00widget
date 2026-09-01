import Foundation

public struct MarketingPreviewFixtures: Codable, Sendable {
    public struct Countdown: Codable, Sendable {
        public var title: String
        public var date: String
    }

    public struct Mars: Codable, Sendable {
        public var distanceKm: Int
        public var lightMinutes: Double
    }

    public struct Weekend: Codable, Sendable {
        public var title: String
        public var status: String
        public var temperature: Int
        public var wind: Int
    }

    public var referenceDate: String?
    public var countdown: Countdown
    public var mars: Mars
    public var weekend: Weekend

    public static let previewDefault = MarketingPreviewFixtures(
        referenceDate: "2026-09-01T09:41:00Z",
        countdown: Countdown(title: "Julia turns 12", date: "2026-10-16"),
        mars: Mars(distanceKm: 225_000_000, lightMinutes: 12.5),
        weekend: Weekend(
            title: "Beach this weekend?",
            status: "YES",
            temperature: 27,
            wind: 11
        )
    )
}

public enum SampleDataFactory {
    /// Sample cards live in the reserved `sample-` id namespace so the app and
    /// the widget extension can badge them and offer to remove them without
    /// mistaking a published card for a demo one.
    public static func sampleId(_ suffix: String) -> String {
        ZeroZeroWidgetConstants.sampleCardIdPrefix + suffix
    }

    /// Stable fixtures for the App Store Preview. Values are calculated from a
    /// caller-provided reference date rather than the wall clock, so recaptures
    /// do not silently change their numbers.
    public static func makeMarketingPreviewCards(
        referenceDate: Date,
        fixtures: MarketingPreviewFixtures = .previewDefault
    ) -> [DashboardCard] {
        let calendar = Calendar(identifier: .gregorian)
        let deadline = ZeroZeroWidgetDateFormat.parse("\(fixtures.countdown.date)T09:00:00Z")
            ?? ZeroZeroWidgetDateFormat.parse("2026-10-16T09:00:00Z")!
        let days = max(
            0,
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: referenceDate),
                to: calendar.startOfDay(for: deadline)
            ).day ?? 0
        )
        let weekends = Int(ceil(Double(days) / 7.0))
        let freshUntil = Date.distantFuture
        let distanceMillions = Double(fixtures.mars.distanceKm) / 1_000_000
        let distance = distanceMillions.rounded() == distanceMillions
            ? String(Int(distanceMillions))
            : String(format: "%.1f", distanceMillions)
        return [
            DashboardCard(
                id: sampleId("preview-countdown"),
                template: .summary,
                title: fixtures.countdown.title,
                subtitle: "\(weekends) weekends",
                value: String(days),
                unit: "days",
                status: .good,
                icon: "birthday.cake",
                updatedAt: referenceDate,
                staleAfter: freshUntil
            ),
            DashboardCard(
                id: sampleId("preview-mars"),
                template: .chart,
                title: "Mars",
                subtitle: "\(String(format: "%.1f", fixtures.mars.lightMinutes)) light-minutes",
                value: "\(distance)M",
                unit: "km",
                status: .good,
                icon: "sparkles",
                updatedAt: referenceDate,
                staleAfter: freshUntil,
                chart: DashboardChart(
                    points: [168, 181, 197, 214, 232, 239, distanceMillions],
                    min: 150,
                    max: 250,
                    semantic: MetricSemantic(
                        role: .actual,
                        signal: .favorable
                    ),
                    style: .line,
                    labels: ["Mar", "Apr", "May", "Jun", "Jul", "Aug", "Now"]
                )
            ),
            DashboardCard(
                id: sampleId("preview-weekend"),
                template: .chart,
                title: fixtures.weekend.title,
                subtitle: "\(fixtures.weekend.temperature)°C · wind \(fixtures.weekend.wind) km/h",
                value: fixtures.weekend.status,
                status: .good,
                icon: "beach.umbrella",
                updatedAt: referenceDate,
                staleAfter: freshUntil,
                chart: DashboardChart(
                    points: [],
                    min: 14,
                    max: 30,
                    semantic: MetricSemantic(
                        role: .forecast,
                        signal: .favorable
                    ),
                    style: .range,
                    labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
                    rangeValueLabel: "Average",
                    ranges: [
                        DashboardChartRange(low: 16, high: 22, value: 19),
                        DashboardChartRange(low: 17, high: 23, value: 20),
                        DashboardChartRange(low: 18, high: 25, value: 21.5),
                        DashboardChartRange(low: 17, high: 24, value: 20.5),
                        DashboardChartRange(low: 19, high: 26, value: 22.5),
                        DashboardChartRange(low: 20, high: 28, value: 24),
                        DashboardChartRange(
                            low: 19,
                            high: Double(fixtures.weekend.temperature),
                            value: 23
                        ),
                    ]
                )
            ),
        ]
    }

    public static func makeCards() -> [DashboardCard] {
        let now = Date()
        let energySolar = [
            11.8, 12.1, 13.4, 10.7, 9.9, 14.1, 15.0, 12.6, 11.2, 10.4,
            8.9, 9.6, 13.7, 16.1, 14.8, 12.2, 10.5, 9.1, 7.8, 8.5,
            11.3, 13.0, 12.1, 10.3, 9.0, 7.4, 6.9, 9.7, 10.1, 9.4,
        ]
        let energyGrid = [
            10.0, 8.8, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0,
            9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0,
            9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0, 9.0,
        ]
        let energyTotals = zip(energySolar, energyGrid).map { $0.0 + $0.1 }
        let energyCategories = energyTotals.enumerated().map { index, total in
            DashboardChartCategory(
                id: "day-\(index + 1)",
                label: String(index + 1),
                signal: total > 24 ? .unfavorable : (total > 22 ? .caution : .favorable)
            )
        }
        return [
            DashboardCard(
                id: sampleId("solar"),
                template: .summary,
                title: "Solar",
                subtitle: "Exporting 0.8 kW",
                value: "3.2",
                unit: "kW",
                status: .good,
                icon: "sun.max",
                updatedAt: now,
                chart: DashboardChart(
                    points: [1.1, 1.6, 2.0, 2.5, 2.2, 2.8, 3.2],
                    min: 0,
                    max: 4,
                    semantic: MetricSemantic(
                        role: .actual,
                        flow: .outbound,
                        signal: .favorable
                    ),
                    style: .line,
                    labels: ["08", "09", "10", "11", "12", "13", "Now"]
                )
            ),
            DashboardCard(
                id: sampleId("services"),
                template: .list,
                title: "Services",
                status: .warning,
                icon: "server.rack",
                updatedAt: now,
                items: [
                    DashboardItem(id: "api", title: "API", value: "142", unit: "ms", status: .good, amount: 142),
                    DashboardItem(id: "database", title: "Database", value: "8", unit: "ms", status: .good, amount: 8),
                    DashboardItem(id: "queue", title: "Queue", value: "1204", unit: "jobs", status: .warning, amount: 1204),
                    DashboardItem(id: "webhooks", title: "Webhooks", value: "3", unit: "failed", status: .critical, amount: 3)
                ]
            ),
            DashboardCard(
                id: sampleId("boiler"),
                template: .action,
                title: "Boiler",
                subtitle: "Manual mode available",
                value: "Ready",
                status: .good,
                icon: "flame",
                statusIcon: "bolt.fill",
                updatedAt: now,
                actions: [
                    ActionDefinition(id: "boiler-boost-1h", label: "Boost 1h")
                ]
            ),
            DashboardCard(
                id: sampleId("car-charge"),
                template: .progress,
                title: "Car",
                subtitle: "Charging at 7.4 kW",
                value: "0.62",
                unit: nil,
                status: .running,
                icon: "car.fill",
                statusIcon: "arrow.up",
                updatedAt: now
            ),
            DashboardCard(
                id: sampleId("nightly-run"),
                template: .briefing,
                title: "Nightly run",
                subtitle: "Step 3 of 5 · 2 need review",
                value: "Migrating",
                status: .running,
                icon: "moon.stars.fill",
                updatedAt: now,
                briefing: DashboardBriefing(sections: [
                    DashboardBriefingSection(
                        id: "stage",
                        label: "Now",
                        text: "Migrating 12,400 records. Throughput is steady and nothing has been rejected."
                    ),
                    DashboardBriefingSection(
                        id: "next",
                        label: "Next",
                        text: "The verification suite runs once the migration drains, then the report is published."
                    ),
                    DashboardBriefingSection(
                        id: "attention",
                        label: "Attention",
                        text: "Two records have conflicting timestamps and are queued for review in the morning."
                    ),
                ])
            ),
            DashboardCard(
                id: sampleId("energy-trend"),
                template: .chart,
                title: "Energy",
                subtitle: "Last 30 days",
                value: "18.4",
                unit: "kWh",
                status: .good,
                icon: "chart.bar.xaxis",
                updatedAt: now,
                chart: DashboardChart(
                    points: energyTotals,
                    min: 0,
                    max: 30,
                    reference: 20,
                    referenceMetadata: DashboardChartReferenceMetadata(
                        label: "Daily target",
                        semantic: MetricSemantic(role: .target)
                    ),
                    semantic: MetricSemantic(role: .actual),
                    style: .bar,
                    categories: energyCategories,
                    series: [
                        DashboardChartSeries(
                            id: "solar",
                            label: "Solar",
                            points: energySolar,
                            semantic: MetricSemantic(
                                flow: .inbound,
                                signal: .favorable
                            )
                        ),
                        DashboardChartSeries(
                            id: "grid",
                            label: "Grid",
                            points: energyGrid,
                            semantic: MetricSemantic(
                                flow: .inbound,
                                signal: .neutral
                            )
                        ),
                    ],
                    stacking: .stacked
                )
            ),
            DashboardCard(
                id: sampleId("deploys"),
                template: .history,
                title: "Deploys",
                subtitle: "Last 20 runs",
                value: "18/20",
                status: .warning,
                icon: "arrow.triangle.2.circlepath",
                updatedAt: now,
                items: [
                    DashboardItem(id: "1", title: "#463", value: "3m 43s", status: .good),
                    DashboardItem(id: "2", title: "#464", value: "4m 15s", status: .good),
                    DashboardItem(id: "3", title: "#465", value: "3m 38s", status: .good),
                    DashboardItem(id: "4", title: "#466", value: "4m 29s", status: .good),
                    DashboardItem(id: "5", title: "#467", value: "3m 56s", status: .good),
                    DashboardItem(id: "6", title: "#468", value: "4m 07s", status: .good),
                    DashboardItem(id: "7", title: "#469", value: "1m 18s", status: .critical),
                    DashboardItem(id: "8", title: "#470", value: "4m 34s", status: .good),
                    DashboardItem(id: "9", title: "#471", value: "3m 27s", status: .good),
                    DashboardItem(id: "10", title: "#472", value: "4m 08s", status: .good),
                    DashboardItem(id: "11", title: "#473", value: "3m 51s", status: .good),
                    DashboardItem(id: "12", title: "#474", value: "4m 02s", status: .good),
                    DashboardItem(id: "13", title: "#475", value: "3m 12s", status: .good),
                    DashboardItem(id: "14", title: "#476", value: "5m 18s", status: .good),
                    DashboardItem(id: "15", title: "#477", value: "1m 04s", status: .critical),
                    DashboardItem(id: "16", title: "#478", value: "4m 41s", status: .good),
                    DashboardItem(id: "17", title: "#479", value: "3m 55s", status: .good),
                    DashboardItem(id: "18", title: "#480", value: "4m 22s", status: .good),
                    DashboardItem(id: "19", title: "#481", value: "2m 48s", status: .good),
                    DashboardItem(id: "20", title: "#482", value: "4m 12s", status: .good),
                ]
            ),
            DashboardCard(
                id: sampleId("device-fleet"),
                template: .breakdown,
                title: "Device fleet",
                subtitle: "Current status",
                value: "24",
                status: .warning,
                icon: "desktopcomputer",
                updatedAt: now,
                items: [
                    DashboardItem(id: "healthy", title: "Healthy", value: "14", status: .good, amount: 14),
                    DashboardItem(id: "updating", title: "Updating", value: "5", status: .running, amount: 5),
                    DashboardItem(id: "attention", title: "Attention", value: "3", status: .warning, amount: 3),
                    DashboardItem(id: "offline", title: "Offline", value: "2", status: .offline, amount: 2),
                ]
            )
        ]
    }

    /// Uses the reserved `sample-` prefix like the demo cards, so the app can
    /// badge it and offer to remove it without mistaking it for an activity an
    /// agent started.
    public static func makeLiveActivitySession() -> LiveActivitySession {
        LiveActivitySession(
            externalActivityId: sampleId("home-battery"),
            kind: .charging,
            title: "Home battery",
            subtitle: "Charging from solar",
            state: "charging",
            signal: .favorable,
            icon: "battery.100percent.bolt",
            statusIcon: "bolt.fill",
            value: "95",
            unit: "%",
            progress: 0.95,
            chart: DashboardChart(
                // Recent state of charge. A simple historical line agrees
                // with the 95% headline; uncertainty ranges belong to samples
                // whose subject is explicitly a forecast.
                points: [
                    38, 45, 51, 57, 64, 69,
                    74, 82, 87, 91, 93, 95,
                ],
                min: 30,
                max: 100,
                reference: 100,
                referenceMetadata: DashboardChartReferenceMetadata(
                    label: "Full charge",
                    semantic: MetricSemantic(role: .capacity)
                ),
                semantic: MetricSemantic(role: .actual),
                style: .line,
                labels: ["−110m", "−100m", "−90m", "−80m", "−70m", "−60m", "−50m", "−40m", "−30m", "−20m", "−10m", "Now"]
            ),
            startedAt: Date(),
            updatedAt: Date(),
            staleAt: Date().addingTimeInterval(3600)
        )
    }
}
