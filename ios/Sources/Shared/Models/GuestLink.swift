import Foundation

/// A link someone shared with this device, granting read-only access to exactly
/// one card or one Live Activity on somebody else's account.
///
/// The token is the identity: a guest receives nothing but the token (from a QR
/// code's URL fragment, or the scanner) and learns what it unlocks only by
/// calling the server. Everything else here is a cache of the last successful
/// answer, so the list still renders something meaningful offline.
public struct GuestLink: Codable, Identifiable, Equatable, Sendable {
    public var id: String { token }
    public let token: String
    public var resourceKind: String?
    public var resourceId: String?
    public var title: String?
    public var expiresAt: Date?
    public var addedAt: Date

    public init(
        token: String,
        resourceKind: String? = nil,
        resourceId: String? = nil,
        title: String? = nil,
        expiresAt: Date? = nil,
        addedAt: Date = Date()
    ) {
        self.token = token
        self.resourceKind = resourceKind
        self.resourceId = resourceId
        self.title = title
        self.expiresAt = expiresAt
        self.addedAt = addedAt
    }

    /// Guest tokens never renew on use, so an elapsed deadline is final — the
    /// server will refuse it and no amount of retrying changes that.
    public var hasExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// Server tokens are opaque, but the prefix is stable and distinguishes a guest
/// link from a tenant API key pasted into the wrong box.
public enum GuestToken {
    public static let prefix = "zwg_"

    public static func looksValid(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return false }
        let body = trimmed.dropFirst(prefix.count)
        return body.count == 43 && body.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    /// Pulls the token out of a shared link. The token is in the fragment, so
    /// `URLComponents.fragment` is the only place worth looking — see
    /// `server/src/guestLinks.ts` for why it is never in the path.
    public static func fromURL(_ url: URL) -> String? {
        guard
            let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
            looksValid(fragment)
        else { return nil }
        return fragment
    }

    /// Accepts either a bare token (the scanner may see one) or a full link.
    public static func fromScannedText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksValid(trimmed) { return trimmed }
        guard let url = URL(string: trimmed) else { return nil }
        return fromURL(url)
    }
}
