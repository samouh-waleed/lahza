import Foundation

/// An optional property that always encodes, writing `null` when it is nil (JS `value ?? null`).
///
/// Synthesized `Codable` leaves nil optionals out (like JS `undefined`). Where a format needs an
/// explicit `null` (`deletedAt: null`) instead of a missing key, mark those properties:
///
/// ```swift
/// struct Record: Codable {
///     var id: String
///     @ExplicitNull var revision: Int?
///     @ExplicitNull var deletedAt: String?
/// }
/// ```
///
/// It works with ``JSONValueEncoder`` and Foundation's `JSONEncoder` alike. Decoding accepts a
/// missing key, `null` or a value. To write every nil as `null`, use
/// ``JSONValueEncoder/NilEncoding/null`` instead.
@propertyWrapper
public struct ExplicitNull<Wrapped> {
    /// The wrapped optional.
    public var wrappedValue: Wrapped?

    public init(wrappedValue: Wrapped?) {
        self.wrappedValue = wrappedValue
    }
}

extension ExplicitNull: Sendable where Wrapped: Sendable {}
extension ExplicitNull: Equatable where Wrapped: Equatable {}
extension ExplicitNull: Hashable where Wrapped: Hashable {}

extension ExplicitNull: Encodable where Wrapped: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

extension ExplicitNull: Decodable where Wrapped: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Wrapped.self)
    }
}

extension KeyedDecodingContainer {
    /// Lets a synthesized `init(from:)` accept a missing key for an ``ExplicitNull`` property.
    public func decode<Wrapped: Decodable>(_ type: ExplicitNull<Wrapped>.Type, forKey key: Key) throws -> ExplicitNull<Wrapped> {
        try decodeIfPresent(type, forKey: key) ?? ExplicitNull(wrappedValue: nil)
    }
}
