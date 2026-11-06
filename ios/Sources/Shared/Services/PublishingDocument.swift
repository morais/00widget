import Foundation

/// Lossless public-API JSON. Unlike decoding through a read model, this keeps
/// write-only action definitions and explicit nulls in partial updates intact.
public struct PublishingDocument: Codable {
    public enum Value: Codable {
        case null, bool(Bool), number(Double), string(String), array([Value]), object([String: Value])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([Value].self) { self = .array(v) }
            else { self = .object(try c.decode([String: Value].self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }

    public var fields: [String: Value]

    public init(json: String) throws {
        guard let data = json.data(using: .utf8), data.count <= 64 * 1024 else {
            throw APIClientError(status: 0, message: "Publishing content must be at most 64 KB.")
        }
        fields = try JSONDecoder().decode([String: Value].self, from: data)
    }

    public init(from decoder: Decoder) throws {
        fields = try decoder.singleValueContainer().decode([String: Value].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fields)
    }

    public func string(_ key: String) -> String? {
        guard case .string(let value) = fields[key] else { return nil }
        return value
    }

    public mutating func set(_ key: String, _ value: String) {
        fields[key] = .string(value)
    }
}
