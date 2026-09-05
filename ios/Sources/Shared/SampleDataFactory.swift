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

    /// The four cards the App Store's four-cell metrics image shows, in the
    /// order it shows them.
    ///
    /// Named here rather than inside the screenshot-only widget that draws
    /// them because `CardGridFitTests` has to assert against the same list:
    /// the rule it enforces — that no approved promotional image contains an
    /// ellipsis — is about these four cards in a grid cell, not about the deck
    /// in general. A card outside this list may legitimately carry a subtitle
    /// too long for one, since every other surface gives it more room.
    public static let marketingGridCardSuffixes = ["trials", "support", "agent-runs", "ai-spend"]

    public static func makeCards() -> [DashboardCard] {
        let now = Date()
        return [
            DashboardCard(
                id: sampleId("launch"),
                template: .briefing,
                title: "Launch",
                subtitle: "Release Agent · final approval",
                value: "4/5",
                status: .warning,
                icon: "shippingbox.fill",
                producer: CardProducer(label: "Release Agent", icon: "sparkles"),
                progress: 0.8,
                updatedAt: now,
                // No countdown while a person is the thing being waited on: a
                // clock cannot predict when someone decides.
                briefing: DashboardBriefing(sections: [
                    DashboardBriefingSection(
                        id: "now",
                        label: "Now",
                        text: "Build and tests passed. Store uploaded; website live."
                    ),
                    DashboardBriefingSection(
                        id: "next",
                        label: "Next",
                        text: "Start the 10% rollout and publish the release notes after approval."
                    ),
                    DashboardBriefingSection(
                        id: "needs-you",
                        label: "Needs you",
                        text: "Approve the customer announcement."
                    ),
                ]),
                // A customer announcement is consequential enough that the
                // widget must route to the app's confirmation step rather than
                // approving on one tap.
                actions: [ActionDefinition(id: "approve-launch", label: "Approve", confirm: true)]
            ),
            DashboardCard(
                id: sampleId("production"),
                template: .list,
                title: "Production",
                subtitle: "Ops Agent · checked now",
                status: .good,
                icon: "server.rack",
                producer: CardProducer(label: "Ops Agent", icon: "gearshape.2"),
                updatedAt: now,
                items: [
                    DashboardItem(id: "api", title: "API", value: "118", unit: "ms", status: .good, amount: 118),
                    DashboardItem(id: "checkout", title: "Checkout", value: "99.99", unit: "%", status: .good, amount: 99.99),
                    DashboardItem(id: "queue", title: "Queue", value: "0", unit: "waiting", status: .good, amount: 0),
                ]
            ),
            DashboardCard(
                id: sampleId("trials"),
                template: .chart,
                title: "Trials",
                subtitle: "Growth Agent · this week",
                value: "128",
                unit: "today",
                status: .good,
                icon: "chart.line.uptrend.xyaxis",
                producer: CardProducer(label: "Growth Agent", icon: "sparkles"),
                comparison: CardComparison(value: "+18", label: "vs Monday", signal: .favorable),
                updatedAt: now,
                chart: DashboardChart(
                    points: [110, 111, 114, 116, 119, 123, 128],
                    min: 108,
                    max: 130,
                    reference: 110,
                    referenceMetadata: DashboardChartReferenceMetadata(
                        label: "Monday",
                        semantic: MetricSemantic(role: .baseline)
                    ),
                    semantic: MetricSemantic(role: .actual, signal: .favorable),
                    style: .line,
                    labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Today"]
                )
            ),
            DashboardCard(
                id: sampleId("support"),
                template: .breakdown,
                title: "Support",
                subtitle: "1 waiting",
                value: "24",
                // Healthy overall: the single amber segment inside the
                // breakdown is what makes the distribution credible, and the
                // launch approval stays the deck's only decision.
                status: .good,
                icon: "person.2.wave.2",
                producer: CardProducer(label: "Support Agent", icon: "sparkles"),
                updatedAt: now,
                items: [
                    DashboardItem(id: "waiting", title: "Waiting", value: "1", status: .warning, amount: 1),
                    DashboardItem(id: "resolved", title: "Resolved", value: "18", status: .good, amount: 18),
                    DashboardItem(id: "draft-ready", title: "Draft ready", value: "5", status: .running, amount: 5),
                ],
                actions: [ActionDefinition(id: "open-support", label: "Review")]
            ),
            DashboardCard(
                id: sampleId("ai-spend"),
                template: .progress,
                title: "AI spend",
                subtitle: "of $30 today · $11.60 left",
                value: "$18.40",
                status: .good,
                icon: "dollarsign.circle",
                producer: CardProducer(label: "Usage Agent", icon: "sparkles"),
                progress: 0.613,
                updatedAt: now
            ),
            DashboardCard(
                id: sampleId("agent-runs"),
                template: .history,
                title: "Agent runs",
                subtitle: "19 clean · 1 retried",
                value: "20/20",
                status: .good,
                icon: "checkmark.circle",
                producer: CardProducer(label: "Run Agent", icon: "sparkles"),
                updatedAt: now,
                items: [
                    DashboardItem(id: "1", title: "Run 1", value: "Passed", status: .good),
                    DashboardItem(id: "2", title: "Run 2", value: "Passed", status: .good),
                    DashboardItem(id: "3", title: "Run 3", value: "Passed", status: .good),
                    DashboardItem(id: "4", title: "Run 4", value: "Passed", status: .good),
                    DashboardItem(id: "5", title: "Run 5", value: "Passed", status: .good),
                    DashboardItem(id: "6", title: "Run 6", value: "Passed", status: .good),
                    DashboardItem(id: "7", title: "Run 7", value: "Passed", status: .good),
                    DashboardItem(id: "8", title: "Run 8", value: "Passed", status: .good),
                    DashboardItem(id: "9", title: "Run 9", value: "Passed", status: .good),
                    DashboardItem(id: "10", title: "Run 10", value: "Passed", status: .good),
                    DashboardItem(id: "11", title: "Run 11", value: "Passed", status: .good),
                    DashboardItem(id: "12", title: "Run 12", value: "Passed", status: .good),
                    DashboardItem(id: "13", title: "Run 13", value: "Passed", status: .good),
                    DashboardItem(id: "14", title: "Run 14", value: "Passed", status: .good),
                    DashboardItem(id: "15", title: "Run 15", value: "Passed", status: .good),
                    DashboardItem(id: "16", title: "Run 16", value: "Passed", status: .good),
                    DashboardItem(id: "17", title: "Run 17", value: "Passed", status: .good),
                    DashboardItem(id: "18", title: "Run 18", value: "Passed", status: .good),
                    DashboardItem(id: "19", title: "Run 19", value: "Passed", status: .good),
                    DashboardItem(id: "20", title: "Run 20", subtitle: "Recovered after retry", value: "Passed", status: .good),
                ]
            ),
            DashboardCard(
                id: sampleId("open-prs"),
                template: .summary,
                title: "Open PRs",
                subtitle: "All reviewed",
                value: "3",
                status: .good,
                icon: "arrow.triangle.branch",
                producer: CardProducer(label: "Code Agent", icon: "chevron.left.forwardslash.chevron.right"),
                updatedAt: now
            )
        ]
    }

    /// The original household/operations samples retained for the dedicated
    /// secondary campaign. They are intentionally not mixed into the default
    /// product-launch story.
    public static func makeHomeEnergyCards() -> [DashboardCard] {
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
                subtitle: "Manual mode",
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
                value: "62",
                unit: "%",
                status: .running,
                icon: "car.fill",
                statusIcon: "arrow.up",
                progress: 0.62,
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
                progress: 0.6,
                updatedAt: now,
                deadline: now.addingTimeInterval(45 * 60),
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
                    DashboardItem(id: "7", title: "#469", value: "Failed", status: .critical),
                    DashboardItem(id: "8", title: "#470", value: "4m 34s", status: .good),
                    DashboardItem(id: "9", title: "#471", value: "3m 27s", status: .good),
                    DashboardItem(id: "10", title: "#472", value: "4m 08s", status: .good),
                    DashboardItem(id: "11", title: "#473", value: "3m 51s", status: .good),
                    DashboardItem(id: "12", title: "#474", value: "4m 02s", status: .good),
                    DashboardItem(id: "13", title: "#475", value: "3m 12s", status: .good),
                    DashboardItem(id: "14", title: "#476", value: "5m 18s", status: .good),
                    DashboardItem(id: "15", title: "#477", value: "Failed", status: .critical),
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


    /// Which demo a generated Live Activity shows.
    ///
    /// Two, because the two ways a Live Activity can be built look nothing
    /// alike on the Lock Screen and only one of them was demonstrable. A
    /// `chart` with a headline number draws the plain banner; `items` draw a
    /// row each and suppress the chart entirely. The app shipped only the
    /// first, so the layout an agent is now told to reach for — a job with
    /// named parts — could not be seen anywhere in it.
    ///
    /// One runs at a time. Two would be a better demonstration of exactly one
    /// thing, the Dynamic Island's minimal circle, and would cost the compact
    /// presentation that every other surface and every marketing capture
    /// depends on.
    public enum LiveActivitySample: String, CaseIterable, Sendable {
        case appLaunch
        case captureWorkflow

        public var title: String {
            switch self {
            case .appLaunch: return "App launch"
            case .captureWorkflow: return "Screenshot capture"
            }
        }
    }

    /// Uses the reserved `sample-` prefix like the demo cards, so the app can
    /// badge it and offer to remove it without mistaking it for an activity an
    /// agent started.
    ///
    /// The product-launch job is the default so the app, widgets, Live
    /// Activity, and Apple TV all tell one internally consistent story.
    public static func makeLiveActivitySession(
        _ sample: LiveActivitySample = .appLaunch
    ) -> LiveActivitySession {
        switch sample {
        case .appLaunch: return appLaunchSession()
        case .captureWorkflow: return captureWorkflowSession()
        }
    }

    /// A job made of named parts, which is the shape an agent most often has
    /// and the one `items` exists for.
    ///
    /// The title is "Screenshots" rather than "Marketing screenshot capture"
    /// on purpose. The server now warns a producer whose title is too long for
    /// the Dynamic Island's leading region and names that exact substitution;
    /// a sample that ignored its own advice would be the first thing anyone
    /// copied.
    private static func captureWorkflowSession() -> LiveActivitySession {
        let now = Date()
        return LiveActivitySession(
            externalActivityId: sampleId("screenshot-capture"),
            kind: .job,
            title: "Screenshots",
            subtitle: "Four device sets",
            state: "running",
            signal: .neutral,
            icon: "camera",
            statusIcon: "play.fill",
            // Both, and not one or the other. `value` is the headline the
            // compact island draws; `progress` is what draws the bar and the
            // Watch gauge, and nothing derives it from the string.
            value: "1/4",
            unit: nil,
            progress: 0.25,
            items: [
                LiveActivityItem(
                    id: "iphone-63",
                    title: "iPhone 6.3\"",
                    subtitle: "UI tests running",
                    icon: "iphone",
                    value: "6m 30s",
                    progress: 0.6,
                    status: .running
                ),
                // No `status` on the queued three: a row with no value falls
                // back to its status label, and "Unknown" reads as a fault
                // rather than as a turn that has not come yet.
                LiveActivityItem(id: "iphone-65", title: "iPhone 6.5\"", subtitle: "Queued", icon: "iphone"),
                LiveActivityItem(id: "ipad", title: "iPad", subtitle: "Queued", icon: "ipad"),
                LiveActivityItem(id: "apple-tv", title: "Apple TV", subtitle: "Queued", icon: "appletv"),
            ],
            // Four rows exercise the Lock Screen's measured row ladder: a
            // roomier banner shows all four, while a tighter one falls back
            // and says what it left out.
            endsAt: now.addingTimeInterval(37 * 60),
            countdownGranularity: .minute,
            startedAt: now,
            updatedAt: now,
            staleAt: now.addingTimeInterval(3600)
        )
    }

    private static func appLaunchSession() -> LiveActivitySession {
        let now = Date()
        return LiveActivitySession(
            externalActivityId: sampleId("app-launch"),
            kind: .job,
            title: "App launch",
            subtitle: "Version 2.4 · five steps",
            state: "Waiting for approval",
            signal: .caution,
            icon: "shippingbox.fill",
            statusIcon: "person.crop.circle.badge.exclamationmark",
            value: "4/5",
            progress: 0.8,
            items: [
                LiveActivityItem(id: "announcement", title: "Announcement", value: "Needs approval", status: .warning),
                LiveActivityItem(id: "store", title: "Store", value: "Uploaded", status: .finished),
                LiveActivityItem(id: "website", title: "Website", value: "Live", status: .finished),
                LiveActivityItem(id: "tests", title: "Tests", value: "412 passed", status: .finished),
                LiveActivityItem(id: "build", title: "Build", value: "Passed", status: .finished),
            ],
            // Deliberately no endsAt: the job is blocked on a person, and an
            // ETA beside "Waiting for approval" claims a clock can predict
            // when they decide. Earlier processing states may carry one.
            startedAt: now.addingTimeInterval(-32 * 60),
            updatedAt: now,
            staleAt: now.addingTimeInterval(3600)
        )
    }
}
