import Foundation

public struct ActionConfirmation: Codable, Hashable, Sendable {
    public var title: String
    public var message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

public struct ActionDefinition: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case normal
        case destructive
    }

    public var id: String
    public var label: String
    public var role: Role
    public var confirm: Bool
    public var confirmation: ActionConfirmation?

    public init(
        id: String,
        label: String,
        role: Role = .normal,
        confirm: Bool = false,
        confirmation: ActionConfirmation? = nil
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.confirm = confirm
        self.confirmation = confirmation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        let rawRole = try c.decodeIfPresent(String.self, forKey: .role) ?? "normal"
        role = Role(rawValue: rawRole) ?? .destructive
        confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? false
        confirmation = try c.decodeIfPresent(ActionConfirmation.self, forKey: .confirmation)
    }

    enum CodingKeys: String, CodingKey {
        case id, label, role, confirm, confirmation
    }

    public var isSafeFromWidget: Bool {
        role == .normal && !confirm
    }

    /// The exact copy and control label every foreground platform presents.
    ///
    /// Older actions have no custom copy, so the fallback says what 00Widget
    /// will send, which card it belongs to, and — when known — who receives it.
    public func confirmationPresentation(for card: DashboardCard) -> ActionConfirmationPresentation {
        confirmationPresentation(cardTitle: card.title, producerLabel: card.producer?.label)
    }

    public func confirmationPresentation(
        cardTitle: String,
        producerLabel: String?
    ) -> ActionConfirmationPresentation {
        let customTitle = confirmation?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let customMessage = confirmation?.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let producer = producerLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = producer.flatMap { $0.isEmpty ? nil : $0 }

        return ActionConfirmationPresentation(
            title: customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Confirm action?",
            message: customMessage.flatMap { $0.isEmpty ? nil : $0 }
                ?? "00Widget will send \u{201c}\(label)\u{201d} for \(cardTitle)"
                + (destination.map { " to \($0)." } ?? "."),
            confirmButtonLabel: label,
            isDestructive: role == .destructive
        )
    }
}

public struct ActionConfirmationPresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let confirmButtonLabel: String
    public let isDestructive: Bool
}
