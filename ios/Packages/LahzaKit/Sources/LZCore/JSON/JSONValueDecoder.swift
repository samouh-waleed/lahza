import Foundation

/// Decodes `Decodable` values straight from a ``JSONValue`` (no re-serialisation), with the key
/// order of the source object visible through `allKeys`.
///
/// JS conventions: `Date` accepts an ISO string (parsed like `Date.parse`, see ``JSDate``) or a
/// millisecond number (`new Date(ms)`); `Data` accepts standard base64; integers must be exact
/// (`2.5` does not decode as `Int`).
public struct JSONValueDecoder: Sendable {
    /// Zone used for ISO date-time strings without an offset, which JS reads as local time.
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    /// Decodes a `T` from `value`.
    public func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try _Unbox.value(value, as: type, codingPath: [], timeZone: timeZone)
    }
}

enum _Unbox {
    static func typeMismatch<T>(_ type: T.Type, _ value: JSONValue, _ path: [any CodingKey]) -> DecodingError {
        let found = switch value {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
        return DecodingError.typeMismatch(type, .init(codingPath: path, debugDescription: "Expected \(type) but found \(found) instead."))
    }

    static func bool(_ value: JSONValue, _ path: [any CodingKey]) throws -> Bool {
        guard case .bool(let flag) = value else { throw typeMismatch(Bool.self, value, path) }
        return flag
    }

    static func string(_ value: JSONValue, _ path: [any CodingKey]) throws -> String {
        guard case .string(let text) = value else { throw typeMismatch(String.self, value, path) }
        return text
    }

    static func double(_ value: JSONValue, _ path: [any CodingKey]) throws -> Double {
        guard case .number(let number) = value else { throw typeMismatch(Double.self, value, path) }
        return number
    }

    static func float(_ value: JSONValue, _ path: [any CodingKey]) throws -> Float {
        Float(try double(value, path))
    }

    static func integer<T: FixedWidthInteger>(_ value: JSONValue, _ type: T.Type, _ path: [any CodingKey]) throws -> T {
        guard case .number(let number) = value else { throw typeMismatch(type, value, path) }
        guard let exact = T(exactly: number) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: path,
                debugDescription: "Parsed JSON number <\(JSNumber.toString(number))> does not fit in \(type)."
            ))
        }
        return exact
    }

    static func value<T: Decodable>(_ value: JSONValue, as type: T.Type, codingPath: [any CodingKey], timeZone: TimeZone) throws -> T {
        if T.self == JSONValue.self, let same = value as? T { return same }
        if T.self == JSONObject.self {
            guard case .object(let object) = value, let same = object as? T else {
                throw typeMismatch(type, value, codingPath)
            }
            return same
        }
        if T.self == Date.self {
            let date: Date?
            switch value {
            case .string(let text): date = JSDate.parseDate(text, timeZone: timeZone)
            case .number(let ms): date = JSDate.timeClip(ms).map(Date.init(jsMilliseconds:))
            default: throw typeMismatch(type, value, codingPath)
            }
            guard let date, let typed = date as? T else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid Date."))
            }
            return typed
        }
        if T.self == Data.self {
            guard case .string(let text) = value else { throw typeMismatch(type, value, codingPath) }
            guard let data = Data(base64Encoded: text), let typed = data as? T else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid base64."))
            }
            return typed
        }
        if T.self == URL.self {
            guard case .string(let text) = value else { throw typeMismatch(type, value, codingPath) }
            guard let url = URL(string: text), let typed = url as? T else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid URL string."))
            }
            return typed
        }
        if T.self == Decimal.self {
            guard case .number(let number) = value, let typed = Decimal(number) as? T else {
                throw typeMismatch(type, value, codingPath)
            }
            return typed
        }
        return try T(from: _JSONValueDecoder(value: value, codingPath: codingPath, timeZone: timeZone))
    }
}

final class _JSONValueDecoder: Decoder, SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [any CodingKey]
    let timeZone: TimeZone
    let userInfo: [CodingUserInfoKey: Any] = [:]

    init(value: JSONValue, codingPath: [any CodingKey], timeZone: TimeZone) {
        self.value = value
        self.codingPath = codingPath
        self.timeZone = timeZone
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else { throw _Unbox.typeMismatch([String: JSONValue].self, value, codingPath) }
        return KeyedDecodingContainer(_KeyedDecoding<Key>(object: object, codingPath: codingPath, timeZone: timeZone))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let array) = value else { throw _Unbox.typeMismatch([JSONValue].self, value, codingPath) }
        return _UnkeyedDecoding(array: array, codingPath: codingPath, timeZone: timeZone)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { self }

    func decodeNil() -> Bool { value.isNull }
    func decode(_ type: Bool.Type) throws -> Bool { try _Unbox.bool(value, codingPath) }
    func decode(_ type: String.Type) throws -> String { try _Unbox.string(value, codingPath) }
    func decode(_ type: Double.Type) throws -> Double { try _Unbox.double(value, codingPath) }
    func decode(_ type: Float.Type) throws -> Float { try _Unbox.float(value, codingPath) }
    func decode(_ type: Int.Type) throws -> Int { try _Unbox.integer(value, type, codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try _Unbox.integer(value, type, codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try _Unbox.integer(value, type, codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try _Unbox.integer(value, type, codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try _Unbox.integer(value, type, codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try _Unbox.integer(value, type, codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try _Unbox.integer(value, type, codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try _Unbox.integer(value, type, codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try _Unbox.integer(value, type, codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try _Unbox.integer(value, type, codingPath) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try _Unbox.value(value, as: type, codingPath: codingPath, timeZone: timeZone)
    }
}

struct _KeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: JSONObject
    let codingPath: [any CodingKey]
    let timeZone: TimeZone

    var allKeys: [Key] { object.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { object.contains(key.stringValue) }

    private func member(_ key: Key) throws -> JSONValue {
        guard let member = object[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath,
                debugDescription: "No value associated with key \(key.stringValue)."
            ))
        }
        return member
    }

    private func path(_ key: Key) -> [any CodingKey] { codingPath + [key] }

    func decodeNil(forKey key: Key) throws -> Bool { try member(key).isNull }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try _Unbox.bool(member(key), path(key)) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try _Unbox.string(member(key), path(key)) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try _Unbox.double(member(key), path(key)) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try _Unbox.float(member(key), path(key)) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try _Unbox.integer(member(key), type, path(key)) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try _Unbox.integer(member(key), type, path(key)) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try _Unbox.integer(member(key), type, path(key)) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try _Unbox.integer(member(key), type, path(key)) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try _Unbox.integer(member(key), type, path(key)) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try _Unbox.integer(member(key), type, path(key)) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try _Unbox.integer(member(key), type, path(key)) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try _Unbox.integer(member(key), type, path(key)) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try _Unbox.integer(member(key), type, path(key)) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try _Unbox.integer(member(key), type, path(key)) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try _Unbox.value(member(key), as: type, codingPath: path(key), timeZone: timeZone)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try _JSONValueDecoder(value: member(key), codingPath: path(key), timeZone: timeZone).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try _JSONValueDecoder(value: member(key), codingPath: path(key), timeZone: timeZone).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        _JSONValueDecoder(value: object["super"] ?? .null, codingPath: codingPath + [_JSONCodingKey.super], timeZone: timeZone)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        _JSONValueDecoder(value: object[key.stringValue] ?? .null, codingPath: path(key), timeZone: timeZone)
    }
}

struct _UnkeyedDecoding: UnkeyedDecodingContainer {
    let array: [JSONValue]
    let codingPath: [any CodingKey]
    let timeZone: TimeZone
    var currentIndex = 0

    init(array: [JSONValue], codingPath: [any CodingKey], timeZone: TimeZone) {
        self.array = array
        self.codingPath = codingPath
        self.timeZone = timeZone
    }

    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }

    private var path: [any CodingKey] { codingPath + [_JSONCodingKey(intValue: currentIndex)] }

    private mutating func next<T>(_ type: T.Type) throws -> JSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(type, .init(codingPath: path, debugDescription: "Unkeyed container is at end."))
        }
        return array[currentIndex]
    }

    private mutating func take<T>(_ decode: (JSONValue, [any CodingKey]) throws -> T) throws -> T {
        let element = try next(T.self)
        let decoded = try decode(element, path)
        currentIndex += 1
        return decoded
    }

    mutating func decodeNil() throws -> Bool {
        guard try next(JSONValue.self).isNull else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try take(_Unbox.bool) }
    mutating func decode(_ type: String.Type) throws -> String { try take(_Unbox.string) }
    mutating func decode(_ type: Double.Type) throws -> Double { try take(_Unbox.double) }
    mutating func decode(_ type: Float.Type) throws -> Float { try take(_Unbox.float) }
    mutating func decode(_ type: Int.Type) throws -> Int { try take { try _Unbox.integer($0, type, $1) } }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try take { try _Unbox.integer($0, type, $1) } }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try take { try _Unbox.integer($0, type, $1) } }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try take { try _Unbox.integer($0, type, $1) } }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try take { try _Unbox.integer($0, type, $1) } }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try take { try _Unbox.integer($0, type, $1) } }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try take { try _Unbox.integer($0, type, $1) } }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try take { try _Unbox.integer($0, type, $1) } }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try take { try _Unbox.integer($0, type, $1) } }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try take { try _Unbox.integer($0, type, $1) } }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let zone = timeZone
        return try take { try _Unbox.value($0, as: type, codingPath: $1, timeZone: zone) }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let zone = timeZone
        return try take { try _JSONValueDecoder(value: $0, codingPath: $1, timeZone: zone).container(keyedBy: type) }
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let zone = timeZone
        return try take { try _JSONValueDecoder(value: $0, codingPath: $1, timeZone: zone).unkeyedContainer() }
    }

    mutating func superDecoder() throws -> any Decoder {
        let zone = timeZone
        return try take { _JSONValueDecoder(value: $0, codingPath: $1, timeZone: zone) }
    }
}
