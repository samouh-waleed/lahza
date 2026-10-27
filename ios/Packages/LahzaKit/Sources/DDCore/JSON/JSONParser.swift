import Foundation

/// A `JSON.parse` failure.
public struct JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    /// What went wrong.
    public let message: String
    /// UTF-8 byte offset into the input where parsing stopped.
    public let offset: Int

    public var description: String { "\(message) at byte \(offset)" }
}

extension JSONValue {
    /// The deepest array/object nesting ``parse(_:)-(String)`` accepts; deeper input throws.
    ///
    /// JS has no fixed limit (only its stack). Parsing, stringifying, equality, `deepMerge` and the
    /// `Codable` bridge all recurse, and a Swift concurrency thread has a 512 KB stack: measured in a
    /// debug build, every one of them survives 192 levels while parsing alone overflows near 384.
    /// 128 keeps a safe margin; the app's documents nest fewer than 10 levels.
    public static let maximumNestingDepth = 128

    /// Parses JSON text exactly like `JSON.parse`, keeping object key order.
    ///
    /// The grammar is strict ECMA-404 as V8 applies it: whitespace is only space, tab, LF and
    /// CR; no BOM, comments, trailing commas, leading zeros, `NaN` or single quotes. Duplicate keys
    /// keep the first position and the last value. Numbers round like JS (`1e400` becomes
    /// Infinity, `-0` stays negative zero).
    ///
    /// One unavoidable difference: a Swift `String` cannot hold a lone UTF-16 surrogate, so an
    /// unpaired `\uD800`-style escape decodes to U+FFFD instead of the raw code unit.
    public static func parse(_ text: String) throws(JSONParseError) -> JSONValue {
        var copy = text
        let result: Result<JSONValue, JSONParseError> = copy.withUTF8 { buffer in
            var parser = JSONParser(bytes: buffer)
            return Result { () throws(JSONParseError) -> JSONValue in try parser.parseDocument() }
        }
        return try result.get()
    }

    /// Parses UTF-8 JSON bytes the way `Response.json()` does: a leading UTF-8 BOM is dropped and
    /// invalid UTF-8 becomes U+FFFD before `JSON.parse` runs.
    public static func parse(_ data: Data) throws(JSONParseError) -> JSONValue {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return try parse(String(decoding: bytes, as: UTF8.self))
    }

    /// `JSONValue.parse(text)` as an initialiser.
    public init(parsing text: String) throws(JSONParseError) {
        self = try JSONValue.parse(text)
    }
}

/// Recursive-descent `JSON.parse` over contiguous UTF-8.
struct JSONParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0
    var depth = 0

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws(JSONParseError) -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw fail("Unexpected non-whitespace character after JSON") }
        return value
    }

    private func fail(_ message: String) -> JSONParseError {
        JSONParseError(message: message, offset: index)
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws(JSONParseError) -> JSONValue {
        guard let byte = current else { throw fail("Unexpected end of JSON input") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw fail("Unexpected token")
        }
    }

    private mutating func expectLiteral(_ literal: StaticString) throws(JSONParseError) {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw fail("Unexpected end of JSON input") }
        let start = literal.utf8Start
        for offset in 0..<count where bytes[index + offset] != start[offset] {
            index += offset
            throw fail("Unexpected token")
        }
        index += count
    }

    private mutating func enter() throws(JSONParseError) {
        depth += 1
        guard depth <= JSONValue.maximumNestingDepth else { throw fail("JSON nesting is too deep") }
    }

    private mutating func parseObject() throws(JSONParseError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // {
        var object = JSONObject()
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            guard current == UInt8(ascii: "\"") else {
                throw fail(current == nil ? "Unexpected end of JSON input" : "Expected property name")
            }
            let key = try parseString()
            skipWhitespace()
            guard current == UInt8(ascii: ":") else {
                throw fail(current == nil ? "Unexpected end of JSON input" : "Expected ':' after property name")
            }
            index += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","):
                index += 1
                skipWhitespace()
            case UInt8(ascii: "}"):
                index += 1
                return .object(object)
            case nil:
                throw fail("Unexpected end of JSON input")
            default:
                throw fail("Expected ',' or '}' after property value")
            }
        }
    }

    private mutating func parseArray() throws(JSONParseError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // [
        var array: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            index += 1
            return .array(array)
        }
        while true {
            array.append(try parseValue())
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","):
                index += 1
                skipWhitespace()
            case UInt8(ascii: "]"):
                index += 1
                return .array(array)
            case nil:
                throw fail("Unexpected end of JSON input")
            default:
                throw fail("Expected ',' or ']' after array element")
            }
        }
    }

    private mutating func parseNumber() throws(JSONParseError) -> JSONValue {
        let start = index
        if current == UInt8(ascii: "-") { index += 1 }
        guard let first = current, isDigit(first) else {
            throw fail(current == nil ? "Unexpected end of JSON input" : "No number after minus sign")
        }
        index += 1
        if first != UInt8(ascii: "0") {
            while let byte = current, isDigit(byte) { index += 1 }
        }
        if current == UInt8(ascii: ".") {
            index += 1
            guard let byte = current, isDigit(byte) else { throw fail("Unterminated fractional number") }
            while let byte = current, isDigit(byte) { index += 1 }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            guard let byte = current, isDigit(byte) else { throw fail("Exponent part is missing a number") }
            while let byte = current, isDigit(byte) { index += 1 }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        // The grammar above is stricter than `Double(_:)`, which rounds correctly (like JS) and
        // yields ±infinity on overflow.
        guard let value = Double(text) else { throw JSONParseError(message: "Invalid number", offset: start) }
        return .number(value)
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private mutating func parseString() throws(JSONParseError) -> String {
        index += 1  // opening quote
        let start = index
        // Fast path: no escapes.
        while let byte = current {
            if byte == UInt8(ascii: "\"") {
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                index += 1
                return text
            }
            if byte == UInt8(ascii: "\\") { break }
            if byte < 0x20 { throw fail("Bad control character in string literal") }
            index += 1
        }
        guard current != nil else { throw fail("Unterminated string in JSON") }
        var buffer: [UInt8] = Array(UnsafeBufferPointer(rebasing: bytes[start..<index]))
        while let byte = current {
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                try parseEscape(into: &buffer)
            case 0..<0x20:
                throw fail("Bad control character in string literal")
            default:
                buffer.append(byte)
                index += 1
            }
        }
        throw fail("Unterminated string in JSON")
    }

    private mutating func parseEscape(into buffer: inout [UInt8]) throws(JSONParseError) {
        guard let byte = current else { throw fail("Unterminated string in JSON") }
        index += 1
        switch byte {
        case UInt8(ascii: "\""): buffer.append(0x22)
        case UInt8(ascii: "\\"): buffer.append(0x5C)
        case UInt8(ascii: "/"): buffer.append(0x2F)
        case UInt8(ascii: "b"): buffer.append(0x08)
        case UInt8(ascii: "f"): buffer.append(0x0C)
        case UInt8(ascii: "n"): buffer.append(0x0A)
        case UInt8(ascii: "r"): buffer.append(0x0D)
        case UInt8(ascii: "t"): buffer.append(0x09)
        case UInt8(ascii: "u"):
            let unit = try parseHex4()
            if (0xD800...0xDBFF).contains(unit), let low = peekLowSurrogateEscape() {
                index += 6
                let scalar = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                appendUTF8(scalar, to: &buffer)
            } else if (0xD800...0xDFFF).contains(unit) {
                appendUTF8(0xFFFD, to: &buffer)  // lone surrogate: see `parse(_:)` docs
            } else {
                appendUTF8(UInt32(unit), to: &buffer)
            }
        default:
            index -= 1
            throw fail("Bad escaped character in JSON")
        }
    }

    private mutating func parseHex4() throws(JSONParseError) -> UInt16 {
        guard index + 4 <= bytes.count else { throw fail("Bad Unicode escape in JSON") }
        var value: UInt16 = 0
        for offset in 0..<4 {
            guard let digit = hexValue(bytes[index + offset]) else {
                index += offset
                throw fail("Bad Unicode escape in JSON")
            }
            value = value << 4 | UInt16(digit)
        }
        index += 4
        return value
    }

    /// Looks ahead for `\uDC00`–`\uDFFF` without consuming it.
    private func peekLowSurrogateEscape() -> UInt16? {
        guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
            return nil
        }
        var value: UInt16 = 0
        for offset in 2..<6 {
            guard let digit = hexValue(bytes[index + offset]) else { return nil }
            value = value << 4 | UInt16(digit)
        }
        return (0xDC00...0xDFFF).contains(value) ? value : nil
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    private func appendUTF8(_ scalarValue: UInt32, to buffer: inout [UInt8]) {
        guard let scalar = Unicode.Scalar(scalarValue) else {
            buffer.append(contentsOf: [0xEF, 0xBF, 0xBD])
            return
        }
        UTF8.encode(scalar) { buffer.append($0) }
    }
}
