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
