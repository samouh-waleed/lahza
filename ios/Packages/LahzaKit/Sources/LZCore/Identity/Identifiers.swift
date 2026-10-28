import CryptoKit
import Foundation
import Synchronization

/// Lowercase UUIDs.
public enum LowercaseUUID {
    /// A fresh random (v4) UUID in lowercase, e.g. `3f2b8c1e-9d4a-4b7e-8f21-0c5d6e7f8a9b`.
    /// `UUID().uuidString` is uppercase, which ``isValid(_:)`` rejects.
    public static func make() -> String {
        UUID().uuidString.lowercased()
    }

    /// Whether `value` matches `^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`.
    /// Lowercase only; versions 1–8; RFC 4122 variant.
    public static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else { return false }
            case 14:
                guard byte >= UInt8(ascii: "1"), byte <= UInt8(ascii: "8") else { return false }
            case 19:
                guard [UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b")].contains(byte) else { return false }
            default:
                guard (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")) else {
                    return false
                }
            }
        }
        return true
    }
}

/// A source of new record ids, injectable so tests are deterministic.
public protocol UUIDGenerator: Sendable {
    /// The next lowercase UUID string.
    func next() -> String
}

/// Random lowercase v4 UUIDs.
public struct SystemUUIDGenerator: UUIDGenerator {
    public init() {}
    public func next() -> String { LowercaseUUID.make() }
}

/// Deterministic, valid lowercase v4 UUIDs for tests: `00000000-0000-4000-8000-000000000001`, …002, ….
public final class SequentialUUIDGenerator: UUIDGenerator {
    private let counter: Mutex<UInt64>

    /// Starts after `start` (the first id ends in `start + 1`).
    public init(start: UInt64 = 0) {
        counter = Mutex(start)
    }

    public func next() -> String {
        let value = counter.withLock { value -> UInt64 in
            value += 1
            return value
        }
        let hex = String(value, radix: 16)
        let tail = String(repeating: "0", count: max(0, 12 - hex.count)) + hex
        return "00000000-0000-4000-8000-" + tail.suffix(12)
    }
}

/// SHA-256 helpers (CryptoKit).
public enum SHA256Hex {
    /// Lowercase hex SHA-256 of `data`.
    public static func hash(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Lowercase hex of any byte sequence.
    public static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// `sha256Hex(data)`: lowercase hex SHA-256.
public func sha256Hex(_ data: Data) -> String { SHA256Hex.hash(data) }

/// The deterministic record id for a natural key.
///
/// `h = sha256hex(json)`, where `json` is `[owner, collection, kind, key]` as compact JSON
/// (``naturalKeyJSON(_:)``), then
/// `h[0..8]-h[8..12]-5h[13..16]-{(hex(h[16]) & 3) | 8}h[17..20]-h[20..32]`.
/// Note `h[12]` is skipped. Writers of the same natural key converge on one id.
public func activityId(owner: String, collection: String, kind: String, key: String) -> String {
    let hash = Array(sha256Hex(naturalKeyJSON([owner, collection, kind, key])).utf8)
    func slice(_ range: Range<Int>) -> String { String(decoding: hash[range], as: UTF8.self) }
    let nibble = Int(hash[16] <= UInt8(ascii: "9") ? hash[16] - UInt8(ascii: "0") : hash[16] - UInt8(ascii: "a") + 10)
    let variant = String((nibble & 3) | 8, radix: 16)
    return "\(slice(0..<8))-\(slice(8..<12))-5\(slice(13..<16))-\(variant)\(slice(17..<20))-\(slice(20..<32))"
}

/// The compact JSON array that ``activityId(owner:collection:kind:key:)`` hashes, e.g.
/// `["device","photos","moment","2024-06-01"]`.
///
/// Written by hand so the bytes are fixed by construction rather than by `JSONEncoder`'s
/// undocumented escaping: `"` and `\` are escaped, control characters use `\b` `\f` `\n` `\r`
/// `\t` or `\u00xx` (lowercase hex), and everything else (`/`, U+007F, U+2028, all non-ASCII) is
/// written as raw UTF-8. The bytes must never change, since they decide every id.
func naturalKeyJSON(_ parts: [String]) -> Data {
    let hexDigits = Array("0123456789abcdef".utf8)
    var out = Data([UInt8(ascii: "[")])
    for (index, part) in parts.enumerated() {
        if index > 0 { out.append(UInt8(ascii: ",")) }
        out.append(UInt8(ascii: "\""))
        // Every byte below 0x80 in UTF-8 is a whole ASCII character, so escaping byte by byte is safe.
        for byte in part.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: #"\""#.utf8)
            case UInt8(ascii: "\\"): out.append(contentsOf: #"\\"#.utf8)
            case 0x08: out.append(contentsOf: #"\b"#.utf8)
            case 0x0C: out.append(contentsOf: #"\f"#.utf8)
            case 0x0A: out.append(contentsOf: #"\n"#.utf8)
            case 0x0D: out.append(contentsOf: #"\r"#.utf8)
            case 0x09: out.append(contentsOf: #"\t"#.utf8)
            case ..<0x20:
                out.append(contentsOf: #"\u00"#.utf8)
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
    out.append(UInt8(ascii: "]"))
    return out
}
