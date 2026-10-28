import Foundation

/// Encodes `Encodable` values straight into a ``JSONValue``, keeping the order in which keys are
/// encoded (synthesized `Codable` encodes in declaration order), so
/// `try JSONValueEncoder().encode(x).jsStringify()` matches `JSON.stringify` of the same JS object
/// literal.
///
/// JS conventions: `Date` becomes its `toISOString()` string (what `JSON.stringify` does via
/// `Date.prototype.toJSON`), `Data` becomes standard base64, `URL` its absolute string. A `Float`
/// is widened through its shortest decimal (`Float(1.6)` encodes as `1.6`, like Foundation's
/// `JSONEncoder`), not its binary expansion.
///
/// Nil optionals: see ``NilEncoding``. Types whose format needs explicit `null`s rather than
/// missing keys must use ``NilEncoding/null`` or mark those properties ``ExplicitNull``.
public struct JSONValueEncoder: Sendable {
    /// What a nil optional property becomes.
    public enum NilEncoding: Sendable, Equatable {
        /// The key is left out, like a JS property whose value is `undefined` (the default,
        /// and what synthesized `encodeIfPresent` does with Foundation's `JSONEncoder`).
        case omit
        /// The key is written with `null`, like JS `value ?? null`.
        case null
    }

    /// What a nil optional property becomes. Arrays always hold `null` for nil elements, as
    /// `JSON.stringify([undefined])` gives `[null]`.
    public var nilEncoding: NilEncoding

    public init(nilEncoding: NilEncoding = .omit) {
        self.nilEncoding = nilEncoding
    }

    /// Encodes `value`.
    public func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValueEncoder.box(value, codingPath: [], options: _EncodingOptions(nilEncoding: nilEncoding))
    }

    static func box<T: Encodable>(_ value: T, codingPath: [any CodingKey], options: _EncodingOptions) throws -> JSONValue {
        switch value {
        case let json as JSONValue: return json
        case let object as JSONObject: return .object(object)
        case let date as Date: return .string(JSDate.isoString(date))
        case let data as Data: return .string(data.base64EncodedString())
        case let url as URL: return .string(url.absoluteString)
        case let decimal as Decimal: return .number(NSDecimalNumber(decimal: decimal).doubleValue)
        default:
            let encoder = _JSONValueEncoder(codingPath: codingPath, options: options)
            try value.encode(to: encoder)
            return encoder.node.resolve()
        }
    }

    /// A `Float` as the `Double` of its shortest decimal (`1.6`, not `1.600000023841858`).
    static func widen(_ value: Float) -> Double {
        Double(value.description) ?? Double(value)
    }
}

struct _EncodingOptions {
    let nilEncoding: JSONValueEncoder.NilEncoding
}

/// Mutable tree the encoder writes into; resolved into a `JSONValue` at the end. Separate stored
/// properties (not an enum payload) keep appends O(1).
final class _EncodingNode {
    enum Kind { case empty, value, array, object }

    var kind: Kind = .empty
    var value: JSONValue = .null
    var elements: [_EncodingNode] = []
    var keys: [String] = []
    var members: [JSStringKey: _EncodingNode] = [:]

    init() {}

    init(_ value: JSONValue) {
        kind = .value
        self.value = value
    }

    func resolve() -> JSONValue {
        switch kind {
        case .empty: return .object(JSONObject())
        case .value: return value
        case .array: return .array(elements.map { $0.resolve() })
        case .object:
            var object = JSONObject()
            for key in keys { if let node = members[JSStringKey(key)] { object[key] = node.resolve() } }
            return .object(object)
        }
    }

    func setValue(_ newValue: JSONValue) {
        kind = .value
        value = newValue
    }

    func ensureObject() {
        guard kind != .object else { return }
        kind = .object
        keys = []
        members = [:]
    }

    func ensureArray() {
        guard kind != .array else { return }
        kind = .array
        elements = []
    }

    func set(_ node: _EncodingNode, forKey key: String) {
        ensureObject()
        if members.updateValue(node, forKey: JSStringKey(key)) == nil { keys.append(key) }
    }

    func append(_ node: _EncodingNode) {
        ensureArray()
        elements.append(node)
    }

    var arrayCount: Int { kind == .array ? elements.count : 0 }
}

final class _JSONValueEncoder: Encoder {
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let node: _EncodingNode
    let options: _EncodingOptions

    init(codingPath: [any CodingKey], options: _EncodingOptions, node: _EncodingNode = _EncodingNode()) {
        self.codingPath = codingPath
        self.options = options
        self.node = node
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.ensureObject()
        return KeyedEncodingContainer(_KeyedEncoding<Key>(node: node, codingPath: codingPath, options: options))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        node.ensureArray()
        return _UnkeyedEncoding(node: node, codingPath: codingPath, options: options)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        _SingleValueEncoding(node: node, codingPath: codingPath, options: options)
    }
}

struct _JSONCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    static let `super` = _JSONCodingKey(stringValue: "super")
}

struct _KeyedEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: _EncodingNode
    let codingPath: [any CodingKey]
    let options: _EncodingOptions

    private func put(_ value: JSONValue, _ key: Key) { node.set(_EncodingNode(value), forKey: key.stringValue) }

    mutating func encodeNil(forKey key: Key) throws { put(.null, key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { put(.bool(value), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { put(.string(value), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { put(.number(value), key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { put(.number(JSONValueEncoder.widen(value)), key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { put(.number(Double(value)), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { put(.number(Double(value)), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { put(.number(Double(value)), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { put(.number(Double(value)), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { put(.number(Double(value)), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { put(.number(Double(value)), key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { put(.number(Double(value)), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { put(.number(Double(value)), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { put(.number(Double(value)), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { put(.number(Double(value)), key) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        put(try JSONValueEncoder.box(value, codingPath: codingPath + [key], options: options), key)
    }

    // Synthesized `Codable` writes optional properties through `encodeIfPresent`. Every overload is
    // implemented so ``JSONValueEncoder/NilEncoding/null`` can write the key with `null`.
    private mutating func present<T>(_ value: T?, _ key: Key, _ encode: (inout Self, T) throws -> Void) throws {
        if let value {
            try encode(&self, value)
        } else if options.nilEncoding == .null {
            put(.null, key)
        }
    }

    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: Int128?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent(_ value: UInt128?, forKey key: Key) throws { try present(value, key) { try $0.encode($1, forKey: key) } }
    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        try present(value, key) { try $0.encode($1, forKey: key) }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = _EncodingNode()
        child.ensureObject()
        node.set(child, forKey: key.stringValue)
        return KeyedEncodingContainer(_KeyedEncoding<NestedKey>(node: child, codingPath: codingPath + [key], options: options))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let child = _EncodingNode()
        child.ensureArray()
        node.set(child, forKey: key.stringValue)
        return _UnkeyedEncoding(node: child, codingPath: codingPath + [key], options: options)
    }

    mutating func superEncoder() -> any Encoder {
        let child = _EncodingNode()
        node.set(child, forKey: _JSONCodingKey.super.stringValue)
        return _JSONValueEncoder(codingPath: codingPath + [_JSONCodingKey.super], options: options, node: child)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        let child = _EncodingNode()
        node.set(child, forKey: key.stringValue)
        return _JSONValueEncoder(codingPath: codingPath + [key], options: options, node: child)
    }
}

struct _UnkeyedEncoding: UnkeyedEncodingContainer {
    let node: _EncodingNode
    let codingPath: [any CodingKey]
    let options: _EncodingOptions
    var count: Int { node.arrayCount }

    private func put(_ value: JSONValue) { node.append(_EncodingNode(value)) }
    private var nextKey: _JSONCodingKey { _JSONCodingKey(intValue: count) }

    mutating func encodeNil() throws { put(.null) }
    mutating func encode(_ value: Bool) throws { put(.bool(value)) }
    mutating func encode(_ value: String) throws { put(.string(value)) }
    mutating func encode(_ value: Double) throws { put(.number(value)) }
    mutating func encode(_ value: Float) throws { put(.number(JSONValueEncoder.widen(value))) }
    mutating func encode(_ value: Int) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int8) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int16) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int32) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int64) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt8) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt16) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt32) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt64) throws { put(.number(Double(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        put(try JSONValueEncoder.box(value, codingPath: codingPath + [nextKey], options: options))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let key = nextKey
        let child = _EncodingNode()
        child.ensureObject()
        node.append(child)
        return KeyedEncodingContainer(_KeyedEncoding<NestedKey>(node: child, codingPath: codingPath + [key], options: options))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let key = nextKey
        let child = _EncodingNode()
        child.ensureArray()
        node.append(child)
        return _UnkeyedEncoding(node: child, codingPath: codingPath + [key], options: options)
    }

    mutating func superEncoder() -> any Encoder {
        let key = nextKey
        let child = _EncodingNode()
        node.append(child)
        return _JSONValueEncoder(codingPath: codingPath + [key], options: options, node: child)
    }
}

struct _SingleValueEncoding: SingleValueEncodingContainer {
    let node: _EncodingNode
    let codingPath: [any CodingKey]
    let options: _EncodingOptions

    private func put(_ value: JSONValue) { node.setValue(value) }

    mutating func encodeNil() throws { put(.null) }
    mutating func encode(_ value: Bool) throws { put(.bool(value)) }
    mutating func encode(_ value: String) throws { put(.string(value)) }
    mutating func encode(_ value: Double) throws { put(.number(value)) }
    mutating func encode(_ value: Float) throws { put(.number(JSONValueEncoder.widen(value))) }
    mutating func encode(_ value: Int) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int8) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int16) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int32) throws { put(.number(Double(value))) }
    mutating func encode(_ value: Int64) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt8) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt16) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt32) throws { put(.number(Double(value))) }
    mutating func encode(_ value: UInt64) throws { put(.number(Double(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        put(try JSONValueEncoder.box(value, codingPath: codingPath, options: options))
    }
}
