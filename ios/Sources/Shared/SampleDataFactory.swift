import Foundation

public enum SampleDataFactory {
    /// Sample cards live in the reserved `sample-` id namespace so the app and
    /// the widget extension can badge them and offer to remove them without
    /// mistaking a published card for a demo one.
    public static func sampleId(_ suffix: String) -> String {
        ZeroZeroWidgetConstants.sampleCardIdPrefix + suffix
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
                signal: total > 24 ? .unfavorable : (total > 20 ? .caution : .favorable)
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
                updatedAt: now
            ),
            DashboardCard(
                id: sampleId("school-balances"),
                template: .list,
                title: "School balances",
                status: .good,
                icon: "creditcard",
                updatedAt: now,
                items: [
                    DashboardItem(id: "child-1", title: "Child 1", value: "12.40", unit: "€", status: .good, amount: 12.4),
                    DashboardItem(id: "child-2", title: "Child 2", value: "8.10", unit: "€", status: .warning, amount: 8.1)
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
                id: sampleId("washer"),
                template: .briefing,
                title: "Washer",
                subtitle: "12 min left · all systems normal",
                value: "Rinse",
                status: .running,
                icon: "washer",
                updatedAt: now,
                briefing: DashboardBriefing(sections: [
                    DashboardBriefingSection(
                        id: "stage",
                        label: "Now",
                        text: "The rinse cycle is running normally. Water heating and drainage are on schedule."
                    ),
                    DashboardBriefingSection(
                        id: "next",
                        label: "Next",
                        text: "A short spin follows, then the load will be ready to unload."
                    ),
                    DashboardBriefingSection(
                        id: "attention",
                        label: "Attention",
                        text: "No action is needed. The machine will notify you when the door unlocks."
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
                // The charging forecast widens and narrows with expected solar
                // input. Each marker is the current best estimate inside its
                // low/high envelope.
                points: [],
                min: 30,
                max: 100,
                reference: 100,
                referenceMetadata: DashboardChartReferenceMetadata(
                    label: "Full charge",
                    semantic: MetricSemantic(role: .capacity)
                ),
                semantic: MetricSemantic(role: .forecast),
                style: .range,
                labels: ["Now", "+10", "+20", "+30", "+40", "+50", "+60", "+70", "+80", "+90", "+100", "+110"],
                ranges: [
                    DashboardChartRange(low: 35, high: 43, value: 38),
                    DashboardChartRange(low: 39, high: 49, value: 45),
                    DashboardChartRange(low: 44, high: 56, value: 51),
                    DashboardChartRange(low: 49, high: 63, value: 57),
                    DashboardChartRange(low: 55, high: 70, value: 64),
                    DashboardChartRange(low: 61, high: 77, value: 69),
                    DashboardChartRange(low: 67, high: 83, value: 74),
                    DashboardChartRange(low: 73, high: 89, value: 82),
                    DashboardChartRange(low: 79, high: 94, value: 87),
                    DashboardChartRange(low: 84, high: 97, value: 91),
                    DashboardChartRange(low: 88, high: 99, value: 93),
                    DashboardChartRange(low: 91, high: 100, value: 95),
                ]
            ),
            startedAt: Date(),
            updatedAt: Date(),
            staleAt: Date().addingTimeInterval(3600)
        )
    }
}
