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
                    DashboardItem(id: "child-1", title: "Child 1", value: "12.40", unit: "€", status: .good),
                    DashboardItem(id: "child-2", title: "Child 2", value: "8.10", unit: "€", status: .warning)
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
                template: .summary,
                title: "Washer",
                subtitle: "Cycle running",
                value: "Rinse",
                status: .running,
                icon: "washer",
                updatedAt: now
            ),
            DashboardCard(
                id: sampleId("energy-trend"),
                template: .chart,
                title: "Energy",
                subtitle: "Last 10 days",
                value: "18.4",
                unit: "kWh",
                status: .good,
                icon: "chart.xyaxis.line",
                updatedAt: now,
                chart: DashboardChart(
                    points: [22.1, 19.8, 24.3, 20.6, 17.2, 15.9, 18.7, 21.4, 19.1, 18.4],
                    reference: 20
                )
            )
            ,
            DashboardCard(
                id: sampleId("deploys"),
                template: .history,
                title: "Deploys",
                subtitle: "Last 10 runs",
                value: "9/10",
                status: .warning,
                icon: "arrow.triangle.2.circlepath",
                updatedAt: now,
                items: [
                    DashboardItem(id: "1", title: "#473", value: "3m 51s", status: .good),
                    DashboardItem(id: "2", title: "#474", value: "4m 02s", status: .good),
                    DashboardItem(id: "3", title: "#475", value: "3m 12s", status: .good),
                    DashboardItem(id: "4", title: "#476", value: "5m 18s", status: .good),
                    DashboardItem(id: "5", title: "#477", value: "1m 04s", status: .critical),
                    DashboardItem(id: "6", title: "#478", value: "4m 41s", status: .good),
                    DashboardItem(id: "7", title: "#479", value: "3m 55s", status: .good),
                    DashboardItem(id: "8", title: "#480", value: "4m 22s", status: .good),
                    DashboardItem(id: "9", title: "#481", value: "2m 48s", status: .good),
                    DashboardItem(id: "10", title: "#482", value: "4m 12s", status: .good),
                ]
            )
            ,
            DashboardCard(
                id: sampleId("spending"),
                template: .breakdown,
                title: "Spending",
                subtitle: "This month",
                value: "394",
                unit: "€",
                status: .good,
                icon: "eurosign.circle",
                updatedAt: now,
                items: [
                    DashboardItem(id: "groceries", title: "Groceries", value: "182", unit: "€", amount: 182.4),
                    DashboardItem(id: "transport", title: "Transport", value: "96", unit: "€", amount: 96.2),
                    DashboardItem(id: "utilities", title: "Utilities", value: "74", unit: "€", amount: 74.1),
                    DashboardItem(id: "other", title: "Other", value: "41", unit: "€", amount: 41.3),
                ]
            )
        ]
    }

    /// Uses the reserved `sample-` prefix like the demo cards, so the app can
    /// badge it and offer to remove it without mistaking it for an activity an
    /// agent started.
    public static func makeLiveActivitySession() -> LiveActivitySession {
        LiveActivitySession(
            externalActivityId: sampleId("washer"),
            kind: .appliance,
            title: "Washing machine",
            subtitle: "Cycle running",
            state: "running",
            value: nil,
            unit: nil,
            progress: nil,
            items: [
                LiveActivityItem(
                    id: "washer",
                    title: "Washer",
                    subtitle: "Rinsing",
                    icon: "washer",
                    value: "18",
                    unit: "min",
                    progress: 0.62,
                    status: .running
                ),
                LiveActivityItem(
                    id: "dryer",
                    title: "Dryer",
                    subtitle: "Ready next",
                    icon: "wind",
                    status: .paused
                ),
            ],
            startedAt: Date(),
            updatedAt: Date(),
            staleAt: Date().addingTimeInterval(3600)
        )
    }
}
