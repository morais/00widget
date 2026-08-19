import Foundation

public struct LiveActivityItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: String?
    /// What this row is doing right now, beside its own icon.
    public var statusIcon: String?
    public var value: String?
    public var unit: String?
    public var progress: Double?
    public var status: DashboardStatus?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        statusIcon: String? = nil,
        value: String? = nil,
        unit: String? = nil,
        progress: Double? = nil,
        status: DashboardStatus? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.statusIcon = statusIcon
        self.value = value
        self.unit = unit
        self.progress = progress
        self.status = status
    }

    public var isActive: Bool {
        status != .finished && status != .offline
    }
}
