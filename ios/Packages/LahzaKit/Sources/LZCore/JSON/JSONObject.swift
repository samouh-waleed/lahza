import Foundation

/// A JSON object that keeps JavaScript property order.
///
/// JS orders an ordinary object's own string keys as: every *array index* key (`"0"` …
/// `"4294967294"`, canonical decimal) in ascending numeric order, then every other key in
/// insertion order. `JSON.parse`, object spread, `Object.keys` and `JSON.stringify` all follow
/// it, so this type does too:
/// - a new key is appended (array-index keys are slotted into the leading numeric run);
/// - assigning to an existing key keeps its position (a duplicate key in `JSON.parse` replaces
///   the value in place);
/// - removing a key forgets its position.
///
/// Keys have JS string identity: they are compared by UTF-16 code units, never by Unicode
/// canonical equivalence, so NFC `"é"` and NFD `"e\u{301}"` (or `"K"` and U+212A KELVIN SIGN) are
/// two different keys, exactly as in JS.
///
/// Equality ignores key order (like `assert.deepEqual`).
public struct JSONObject: Sendable, Hashable {
    /// Keys in JS property order.
    public private(set) var keys: [String]
    private var storage: [JSStringKey: JSONValue]
    /// How many leading entries of `keys` are array-index keys.
    private var indexKeyCount: Int

    /// An empty object.
    public init() {
        keys = []
        storage = [:]
        indexKeyCount = 0
    }

    /// Builds an object by assigning each pair in order (later duplicates replace in place).
    public init<S: Sequence>(_ pairs: S) where S.Element == (String, JSONValue) {
        self.init()
        for (key, value) in pairs { self[key] = value }
    }

    /// Number of keys.
    public var count: Int { keys.count }
    /// True when the object has no keys.
    public var isEmpty: Bool { keys.isEmpty }
    /// Values in key order.
    public var values: [JSONValue] { keys.compactMap { storage[JSStringKey($0)] } }
    /// Whether the object has an own property named `key` (`Object.hasOwn`).
    public func contains(_ key: String) -> Bool { storage[JSStringKey(key)] != nil }

    /// Reads or writes a member. Writing nil removes the key (JS `delete`).
    public subscript(key: String) -> JSONValue? {
        get { storage[JSStringKey(key)] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: JSStringKey(key)) == nil { insertKey(key) }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    /// Removes a key and returns its old value.
    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let old = storage.removeValue(forKey: JSStringKey(key)) else { return nil }
        if let position = keys.firstIndex(where: { jsStringEqual($0, key) }) {
            keys.remove(at: position)
            if position < indexKeyCount { indexKeyCount -= 1 }
        }
        return old
    }

    /// JS object spread `{...self, ...other}` applied in place: each key of `other` is assigned in
    /// order (existing keys keep their position, new keys append). Shallow, unlike `deepMerge`.
    /// Like spread (and unlike `Object.assign`), a `__proto__` key is copied as a plain key.
    public mutating func spread(_ other: JSONObject) {
        for (key, value) in other { self[key] = value }
    }

    /// `{...self, ...others[0], ...others[1], …}` as a new object.
    public func spreading(_ others: JSONObject...) -> JSONObject {
        var result = self
        for other in others { result.spread(other) }
        return result
    }

    /// Key/value pairs in JS property order.
    public var entries: [(key: String, value: JSONValue)] {
        keys.compactMap { key in storage[JSStringKey(key)].map { (key: key, value: $0) } }
    }

    private mutating func insertKey(_ key: String) {
        guard let index = JSONObject.arrayIndex(key) else {
            keys.append(key)
            return
        }
        // Binary search the leading numeric run for the insertion point.
        var low = 0
        var high = indexKeyCount
        while low < high {
            let mid = (low + high) / 2
            if (JSONObject.arrayIndex(keys[mid]) ?? 0) < index { low = mid + 1 } else { high = mid }
        }
        keys.insert(key, at: low)
        indexKeyCount += 1
    }

    /// The numeric value when `key` is a JS array index: canonical decimal `0 … 2^32 - 2`.
    static func arrayIndex(_ key: String) -> UInt32? {
        let utf8 = key.utf8
        guard let first = utf8.first, utf8.count <= 10 else { return nil }
        if first == UInt8(ascii: "0") { return utf8.count == 1 ? 0 : nil }
        var value: UInt64 = 0
        for byte in utf8 {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + UInt64(byte - UInt8(ascii: "0"))
        }
        guard value <= 4_294_967_294 else { return nil }
        return UInt32(value)
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.storage == rhs.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}

extension JSONObject: Sequence {
    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> {
        entries.makeIterator()
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }
}

extension JSONObject: CustomStringConvertible {
    /// The `JSON.stringify` text.
    public var description: String { JSONValue.object(self).jsStringify() }
}
