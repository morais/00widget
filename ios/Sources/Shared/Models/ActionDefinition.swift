import Foundation

public struct ActionDefinition: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case normal
        case destructive
    }

    public var id: String
    public var label: String
    public var role: Role
    public var confirm: Bool

    public init(
        id: String,
        label: String,
        role: Role = .normal,
        confirm: Bool = false
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.confirm = confirm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        let rawRole = try c.decodeIfPresent(String.self, forKey: .role) ?? "normal"
        role = Role(rawValue: rawRole) ?? .destructive
        confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id, label, role, confirm
    }

    public var isSafeFromWidget: Bool {
        role == .normal && !confirm
    }
}
