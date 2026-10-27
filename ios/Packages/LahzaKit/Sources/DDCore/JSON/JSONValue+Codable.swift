import Foundation

/// `Codable` bridging.
///
/// With ``JSONValueEncoder`` / ``JSONValueDecoder`` the value passes through untouched, key order
/// included. With other coders (for example Foundation's `JSONEncoder`/`JSONDecoder`) objects go
/// through a keyed container, and those coders do not promise key order: use
/// ``JSONValue/parse(_:)-(String)`` and ``JSONValue/jsStringify()`` when order or bytes matter.
extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        if let direct = decoder as? _JSONValueDecoder {
            self = direct.value
            return
        }
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
                return
            }
            if let flag = try? container.decode(Bool.self) {
                self = .bool(flag)
                return
            }
            if let number = try? container.decode(Double.self) {
                self = .number(number)
                return
            }
            if let text = try? container.decode(String.self) {
                self = .string(text)
                return
            }
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !unkeyed.isAtEnd { array.append(try unkeyed.decode(JSONValue.self)) }
            self = .array(array)
            return
        }
        let keyed = try decoder.container(keyedBy: _JSONCodingKey.self)
        var object = JSONObject()
        for key in keyed.allKeys { object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key) }
        self = .object(object)
    }

    public func encode(to encoder: any Encoder) throws {
        if let direct = encoder as? _JSONValueEncoder {
            direct.node.setValue(self)
            return
        }
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let flag):
            var container = encoder.singleValueContainer()
            try container.encode(flag)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .string(let text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case .array(let array):
            var container = encoder.unkeyedContainer()
            for element in array { try container.encode(element) }
        case .object(let object):
            var container = encoder.container(keyedBy: _JSONCodingKey.self)
            for (key, member) in object { try container.encode(member, forKey: _JSONCodingKey(stringValue: key)) }
        }
    }
}

extension JSONObject: Codable {
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let object) = value else {
            throw _Unbox.typeMismatch(JSONObject.self, value, decoder.codingPath)
        }
        self = object
    }

    public func encode(to encoder: any Encoder) throws {
        try JSONValue.object(self).encode(to: encoder)
    }
}

extension JSONValue {
    /// Encodes any `Encodable` into a `JSONValue` with ``JSONValueEncoder``.
    public init<T: Encodable>(encoding value: T, nilEncoding: JSONValueEncoder.NilEncoding = .omit) throws {
        self = try JSONValueEncoder(nilEncoding: nilEncoding).encode(value)
    }

    /// Decodes this value as `T` with ``JSONValueDecoder``.
    public func decode<T: Decodable>(_ type: T.Type = T.self, timeZone: TimeZone = .current) throws -> T {
        try JSONValueDecoder(timeZone: timeZone).decode(type, from: self)
    }

    /// `JSON.stringify` of any `Encodable` (encoded with ``JSONValueEncoder``).
    public static func jsStringify<T: Encodable>(_ value: T, nilEncoding: JSONValueEncoder.NilEncoding = .omit) throws -> String {
        try JSONValueEncoder(nilEncoding: nilEncoding).encode(value).jsStringify()
    }

    /// `JSON.parse` followed by decoding as `T`.
    public static func decode<T: Decodable>(_ type: T.Type = T.self, fromJSON text: String, timeZone: TimeZone = .current) throws -> T {
        try JSONValueDecoder(timeZone: timeZone).decode(type, from: parse(text))
    }
}
