import Foundation

/// ECMAScript `Number::toString(10)`: what `String(x)` and `JSON.stringify(x)` print.
public enum JSNumber {
    /// `String(x)` in JS: the shortest round-trip digits in JS layout
    /// (`1e21` → `"1e+21"`, `1e-7` → `"1e-7"`, `100` → `"100"`, `-0` → `"0"`, `NaN` → `"NaN"`).
    public static func toString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == 0 { return "0" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let (digits, n) = shortestDigits(value.magnitude)
        let k = digits.count
        var out = value < 0 ? "-" : ""
        out.reserveCapacity(k + 8)
        func append(_ slice: ArraySlice<UInt8>) { out += String(decoding: slice, as: UTF8.self) }
        if k <= n && n <= 21 {
            append(digits[...])
            out += String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            append(digits[..<n])
            out += "."
            append(digits[n...])
        } else if -6 < n && n <= 0 {
            out += "0."
            out += String(repeating: "0", count: -n)
            append(digits[...])
        } else {
            let exponent = n - 1
            append(digits[..<1])
            if k > 1 {
                out += "."
                append(digits[1...])
            }
            out += exponent < 0 ? "e-" : "e+"
            out += String(exponent.magnitude)
        }
        return out
    }

    /// `JSON.stringify(x)` for a number: ``toString(_:)`` when finite, otherwise `"null"`.
    public static func jsonString(_ value: Double) -> String {
        value.isFinite ? toString(value) : "null"
    }

    /// Shortest round-trip decimal digits `s` (no leading/trailing zeros) and the position `n`
    /// such that `x = 0.s × 10^n`, i.e. ECMAScript's `s × 10^(n−k)`.
    ///
    /// Swift's `Double.description` already prints the shortest digits that round-trip and are
    /// closest to the exact value (SwiftDtoa); only the layout differs from JS, so the digits and
    /// exponent are lifted out of it.
    static func shortestDigits(_ magnitude: Double) -> (digits: [UInt8], point: Int) {
        let text = magnitude.description
        var digits: [UInt8] = []
        digits.reserveCapacity(20)
        var pointPosition: Int?
        var exponent = 0
        var utf8 = text.utf8[...]
        if let e = utf8.firstIndex(where: { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }) {
            exponent = Int(String(decoding: utf8[utf8.index(after: e)...], as: UTF8.self)) ?? 0
            utf8 = utf8[..<e]
        }
        for byte in utf8 {
            if byte == UInt8(ascii: ".") {
                pointPosition = digits.count
            } else if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                digits.append(byte)
            }
        }
        var point = (pointPosition ?? digits.count) + exponent
        var leading = 0
        while leading < digits.count - 1 && digits[leading] == UInt8(ascii: "0") { leading += 1 }
        if leading > 0 {
            digits.removeFirst(leading)
            point -= leading
        }
        while digits.count > 1 && digits.last == UInt8(ascii: "0") { digits.removeLast() }
        return (digits, point)
    }
}

extension JSONValue {
    /// Byte-identical `JSON.stringify(value)` (no indentation).
    ///
    /// Strings escape exactly `"` `\` `\b` `\f` `\n` `\r` `\t`, other code units below U+0020 as
    /// `\u00xx` (lowercase hex) and lone surrogates as `\udxxx`. `/`, U+2028/U+2029 and every other
    /// non-ASCII character are written raw. Numbers use ``JSNumber/jsonString(_:)``.
    public func jsStringify() -> String {
        var writer = JSONWriter(sortKeys: false)
        writer.write(self)
        return writer.output
    }

    /// `json-sorted-keys-v1` canonical text: object keys sorted recursively by UTF-16 code units,
    /// then written exactly like ``jsStringify()``. ``canonicalManifest(_:)`` also drops the
    /// top-level `signature` key.
    ///
    /// As in JS, the sorted object is rebuilt as a JS object, so array-index keys (`"2"`, `"10"`)
    /// still come first in ascending numeric order.
    public func canonicalStringify() -> String {
        var writer = JSONWriter(sortKeys: true)
        writer.write(self)
        return writer.output
    }

    /// The manifest without its top-level `signature` key, as ``canonicalStringify()`` text. These
    /// UTF-8 bytes are what the manifest's Ed25519 signature covers.
    ///
    /// A canonical text longer than ``canonicalManifestMaximumLength`` UTF-16 code units
    /// (`canonical.length`) is too large to verify; check ``isWithinCanonicalManifestLimit(_:)``
    /// before verifying.
    public static func canonicalManifest(_ manifest: JSONObject) -> String {
        var unsigned = manifest
        unsigned["signature"] = nil
        return JSONValue.object(unsigned).canonicalStringify()
    }

    /// The longest canonical manifest accepted for verification, in UTF-16 code units
    /// (`canonical.length`).
    public static let canonicalManifestMaximumLength = 2_000_000

    /// `canonical.length <= 2_000_000`, measured in UTF-16 code units like JS.
    public static func isWithinCanonicalManifestLimit(_ canonical: String) -> Bool {
        canonical.utf16.count <= canonicalManifestMaximumLength
    }

    /// ``jsStringify()`` as UTF-8 bytes (what `fetch` sends for `body: JSON.stringify(x)`).
    public func jsStringifyData() -> Data {
        Data(jsStringify().utf8)
    }

    /// `JSON.stringify(string)`: the quoted, escaped string literal.
    public static func quote(_ string: String) -> String {
        var out = ""
        JSONWriter.appendQuoted(string, to: &out)
        return out
    }

    /// `JSON.stringify` of a JS string given as raw UTF-16 code units, which may include lone
    /// surrogates that a Swift `String` cannot hold.
    public static func quote<C: Sequence>(utf16 units: C) -> String where C.Element == UInt16 {
        var out = ""
        JSONWriter.appendQuotedUTF16(units, to: &out)
        return out
    }
}

/// Compares two strings by UTF-16 code units, like JS `<` and `Array.prototype.sort()`.
public func jsStringLess(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
}

struct JSONWriter {
    let sortKeys: Bool
    var output = ""

    init(sortKeys: Bool) {
        self.sortKeys = sortKeys
    }

    mutating func write(_ value: JSONValue) {
        switch value {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .number(let number): output += JSNumber.jsonString(number)
        case .string(let string): JSONWriter.appendQuoted(string, to: &output)
        case .array(let array):
            output += "["
            for (offset, element) in array.enumerated() {
                if offset > 0 { output += "," }
                write(element)
            }
            output += "]"
        case .object(let object):
            output += "{"
            let keys = sortKeys ? JSONWriter.canonicalKeyOrder(object.keys) : object.keys
            var first = true
            for key in keys {
                guard let member = object[key] else { continue }
                if !first { output += "," }
                first = false
                JSONWriter.appendQuoted(key, to: &output)
                output += ":"
                write(member)
            }
            output += "}"
        }
    }

    /// Key order of `Object.fromEntries(Object.keys(o).sort().map(...))`: array-index keys
    /// ascending numerically, then the rest by UTF-16 code units.
    static func canonicalKeyOrder(_ keys: [String]) -> [String] {
        // `JSONObject.keys` already leads with the array-index keys in numeric order.
        let indexCount = keys.prefix { JSONObject.arrayIndex($0) != nil }.count
        return Array(keys[..<indexCount]) + keys[indexCount...].sorted(by: jsStringLess)
    }

    static func appendQuoted(_ string: String, to out: inout String) {
        // Native Swift strings are valid Unicode (no lone surrogates), so the only question is
        // whether any byte needs escaping. Bridged strings take the exact UTF-16 path.
        let clean: Bool? = string.utf8.withContiguousStorageIfAvailable { bytes in
            !bytes.contains { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C }
        }
        if clean == true {
            out += "\""
            out += string
            out += "\""
        } else {
            appendQuotedUTF16(string.utf16, to: &out)
        }
    }

    static func appendQuotedUTF16<C: Sequence>(_ units: C, to out: inout String) where C.Element == UInt16 {
        out += "\""
        var iterator = units.makeIterator()
        var pending: UInt16?
        while let unit = pending ?? iterator.next() {
            pending = nil
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20: appendEscape(unit, to: &out)
            case 0xD800...0xDBFF:
                guard let next = iterator.next() else {
                    appendEscape(unit, to: &out)
                    break
                }
                if (0xDC00...0xDFFF).contains(next),
                   let scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(next) - 0xDC00)) {
                    out.unicodeScalars.append(scalar)
                } else {
                    appendEscape(unit, to: &out)
                    pending = next
                }
            case 0xDC00...0xDFFF: appendEscape(unit, to: &out)
            default:
                if let scalar = Unicode.Scalar(unit) { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }

    private static let hexDigits = Array("0123456789abcdef".unicodeScalars)

    private static func appendEscape(_ unit: UInt16, to out: inout String) {
        out += "\\u"
        for shift in stride(from: 12, through: 0, by: -4) {
            out.unicodeScalars.append(hexDigits[Int((unit >> UInt16(shift)) & 0xF)])
        }
    }
}
