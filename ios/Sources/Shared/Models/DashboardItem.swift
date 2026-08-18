import Foundation

public struct DashboardItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var value: String?
    public var unit: String?
    public var status: DashboardStatus?
    /// The row's magnitude, for templates that draw items rather than list
    /// them. Deliberately separate from `value`, which is a display string.
    public var amount: Double?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        unit: String? = nil,
        status: DashboardStatus? = nil,
        amount: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.unit = unit
        self.status = status
        self.amount = amount
    }
}
