import Foundation

/// A JSON document with JavaScript semantics.
///
/// - Numbers are IEEE-754 doubles, exactly like a JS `number` (NaN and ±Infinity can be held;
///   they stringify as `null`, as `JSON.stringify` does).
/// - Objects keep JavaScript property order (see ``JSONObject``), so ``jsStringify()`` is
///   byte-identical to `JSON.stringify` for the same value.
/// - Equality is semantic, like Node's `assert.deepEqual`: object key order is ignored, array
///   order is not, and numbers compare with `==` (so `-0 == 0` and `NaN != NaN`).
///   Strings and keys compare by UTF-16 code units like JS `===` (see ``jsStringEqual(_:_:)``),
///   never by Swift's Unicode canonical equivalence.
///   Compare ``jsStringify()`` output when bytes matter.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

// MARK: - Convenience initialisers

extension JSONValue {
    /// A number from any binary integer (converted to `Double` exactly as JS would round it).
    public init<T: BinaryInteger>(_ value: T) { self = .number(Double(value)) }
    /// A number.
    public init(_ value: Double) { self = .number(value) }
    /// A string.
    public init(_ value: String) { self = .string(value) }
    /// A boolean.
    public init(_ value: Bool) { self = .bool(value) }
    /// An array.
    public init(_ value: [JSONValue]) { self = .array(value) }
    /// An object.
    public init(_ value: JSONObject) { self = .object(value) }
    /// `.string` for a value, `.null` for nil (a JS `?? null`).
    public init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
}

// MARK: - Accessors

extension JSONValue {
    /// True for `.null`.
    public var isNull: Bool { if case .null = self { true } else { false } }
    /// The boolean payload, if this is a boolean.
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    /// The number payload, if this is a number.
    public var numberValue: Double? { if case .number(let v) = self { v } else { nil } }
    /// The string payload, if this is a string.
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    /// The array payload, if this is an array.
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    /// The object payload, if this is an object.
    public var objectValue: JSONObject? { if case .object(let v) = self { v } else { nil } }

    /// The number as an `Int` when it is finite, integral and representable (`Number.isInteger`).
    public var intValue: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded(.towardZero) == v else { return nil }
        return Int(exactly: v)
    }

    /// The number as an `Int64` when it is finite, integral and representable.
    public var int64Value: Int64? {
        guard case .number(let v) = self, v.isFinite, v.rounded(.towardZero) == v else { return nil }
        return Int64(exactly: v)
    }

    /// Object member lookup (`value[key]`); nil when this is not an object or the key is absent.
    ///
    /// Setting a value assigns the member (a new key is appended in JS property order) and setting
    /// nil deletes it. Setting a value on a non-object replaces it with a new object holding just
    /// that key; setting nil on a non-object does nothing.
    public subscript(key: String) -> JSONValue? {
        get { if case .object(let object) = self { object[key] } else { nil } }
        set {
            if case .object(var object) = self {
                object[key] = newValue
                self = .object(object)
            } else if let newValue {
                self = .object([key: newValue])
            }
        }
    }

    /// Dotted-path access (`"a.b.c"`).
    ///
    /// The path is split on every `.` code unit (`"a..b"` has an empty middle segment, as with JS
    /// `split(".")`).
    /// - Reading walks own properties of objects and returns nil when a segment is missing or a
    ///   non-object is reached. JS `key in cursor` would also find `Object.prototype` members such
    ///   as `"toString"`; settings paths never name those.
    /// - Writing: missing or non-object intermediates become `{}`, existing keys keep their
    ///   position, and new keys are appended. Writing nil removes the last key (JS stores
    ///   `undefined`, which `JSON.stringify` drops) but still creates the parents.
    public subscript(path path: String) -> JSONValue? {
        get {
            var cursor = self
            for segment in JSONValue.pathSegments(path) {
                guard case .object(let object) = cursor, let next = object[segment] else { return nil }
                cursor = next
            }
            return cursor
        }
        set {
            self = JSONValue.setting(newValue, at: JSONValue.pathSegments(path)[...], in: self)
        }
    }

    /// `dotted.split(".")` by code unit.
    static func pathSegments(_ path: String) -> [String] {
        path.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false).map { String($0) }
    }

    private static func setting(_ value: JSONValue?, at segments: ArraySlice<String>, in node: JSONValue) -> JSONValue {
        guard let key = segments.first else { return value ?? node }
        var object = node.objectValue ?? JSONObject()
        if segments.count == 1 {
            object[key] = value
        } else {
            object[key] = setting(value, at: segments.dropFirst(), in: object[key] ?? .object(JSONObject()))
        }
        return .object(object)
    }

    /// Array element lookup; nil when this is not an array or the index is out of bounds.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// The JS `typeof`-style kind name (`"object"` for null, as in JS).
    public var jsTypeName: String {
        switch self {
        case .null, .object, .array: "object"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        }
    }

    /// JS truthiness (`!!value`): false for null, false, 0, -0, NaN and "".
    public var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let v): v
        case .number(let v): !(v == 0 || v.isNaN)
        case .string(let v): !v.isEmpty
        case .array, .object: true
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    /// Keys are inserted in literal order (JS array-index keys still sort first, as in JS).
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements))
    }
}

// MARK: - Equality

extension JSONValue {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): jsStringEqual(a, b)
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let v): hasher.combine(1); hasher.combine(v)
        case .number(let v): hasher.combine(2); hasher.combine(v == 0 ? 0 : v)
        case .string(let v): hasher.combine(3); jsStringHash(v, into: &hasher)
        case .array(let v): hasher.combine(4); hasher.combine(v)
        case .object(let v): hasher.combine(5); hasher.combine(v)
        }
    }
}

extension JSONValue: CustomStringConvertible, CustomDebugStringConvertible {
    /// The `JSON.stringify` text.
    public var description: String { jsStringify() }
    public var debugDescription: String { "JSONValue(\(jsStringify()))" }
}
