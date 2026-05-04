#if ZW_SHARING_ENABLED
import Foundation

public enum ShareResourceKind: String, Codable, Sendable {
    case card
    case activityKind = "activity_kind"
}

public enum ShareStatus: String, Codable, Sendable {
    case pending
    case accepted
    case revoked
    case declined
}

public struct ShareRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var ownerTenantId: String
    public var recipientTenantId: String?
    public var recipientEmail: String
    public var resourceKind: ShareResourceKind
    public var resourceId: String
    public var status: ShareStatus
    public var createdAt: Date?
    public var acceptedAt: Date?
    public var revokedAt: Date?
    public var ownerEmail: String?

    public init(
        id: String,
        ownerTenantId: String,
        recipientTenantId: String? = nil,
        recipientEmail: String,
        resourceKind: ShareResourceKind,
        resourceId: String,
        status: ShareStatus,
        createdAt: Date? = nil,
        acceptedAt: Date? = nil,
        revokedAt: Date? = nil,
        ownerEmail: String? = nil
    ) {
        self.id = id
        self.ownerTenantId = ownerTenantId
        self.recipientTenantId = recipientTenantId
        self.recipientEmail = recipientEmail
        self.resourceKind = resourceKind
        self.resourceId = resourceId
        self.status = status
        self.createdAt = createdAt
        self.acceptedAt = acceptedAt
        self.revokedAt = revokedAt
        self.ownerEmail = ownerEmail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerTenantId = try c.decode(String.self, forKey: .ownerTenantId)
        recipientTenantId = try c.decodeIfPresent(String.self, forKey: .recipientTenantId)
        recipientEmail = try c.decode(String.self, forKey: .recipientEmail)
        resourceKind = try c.decode(ShareResourceKind.self, forKey: .resourceKind)
        resourceId = try c.decode(String.self, forKey: .resourceId)
        status = try c.decode(ShareStatus.self, forKey: .status)
        createdAt = try ShareRecord.decodeDate(c, forKey: .createdAt)
        acceptedAt = try ShareRecord.decodeDate(c, forKey: .acceptedAt)
        revokedAt = try ShareRecord.decodeDate(c, forKey: .revokedAt)
        ownerEmail = try c.decodeIfPresent(String.self, forKey: .ownerEmail)
    }

    enum CodingKeys: String, CodingKey {
        case id, ownerTenantId, recipientTenantId, recipientEmail
        case resourceKind, resourceId, status, createdAt, acceptedAt, revokedAt, ownerEmail
    }

    private static func decodeDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Date? {
        if let s = try container.decodeIfPresent(String.self, forKey: key) {
            return ZeroZeroWidgetDateFormat.parse(s)
        }
        return nil
    }
}
#endif
