import Foundation

// JavaScript compares strings by UTF-16 code units. Swift's `String` `==`, `hasPrefix` and hashing
// use Unicode canonical equivalence instead, so NFC "é" equals NFD "e\u{301}", "K" equals U+212A
// KELVIN SIGN, and Arabic marks typed in a different order compare equal. Everything in LZCore that
// stands in for a JS string comparison uses these helpers instead.
//
// For well-formed strings, UTF-8 byte equality is the same as UTF-16 code-unit equality, and a UTF-8
// byte prefix is the same as a UTF-16 code-unit prefix, so the helpers compare UTF-8 (the native
// storage of Swift strings).

/// JS `a === b` for strings: equal code units, with no Unicode normalization.
public func jsStringEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.utf8
    let right = rhs.utf8
    return left.count == right.count && left.elementsEqual(right)
}

/// JS `string.startsWith(prefix)`: a code-unit prefix, with no Unicode normalization or grapheme
/// rounding.
public func jsStringHasPrefix(_ string: String, _ prefix: String) -> Bool {
    string.utf8.starts(with: prefix.utf8)
}

/// JS `string.endsWith(suffix)`: a code-unit suffix.
public func jsStringHasSuffix(_ string: String, _ suffix: String) -> Bool {
    let bytes = string.utf8
    let tail = suffix.utf8
    guard tail.count <= bytes.count else { return false }
    return bytes.suffix(tail.count).elementsEqual(tail)
}

/// Hashes a string by its UTF-8 bytes, consistent with ``jsStringEqual(_:_:)``.
func jsStringHash(_ string: String, into hasher: inout Hasher) {
    let utf8 = string.utf8
    hasher.combine(utf8.count)
    let hashed: Void? = utf8.withContiguousStorageIfAvailable { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    if hashed == nil {
        for byte in utf8 { hasher.combine(byte) }
    }
}

/// A dictionary key with JS string identity: two keys are the same only when their code units are.
struct JSStringKey: Hashable, Sendable {
    let string: String

    init(_ string: String) {
        self.string = string
    }

    static func == (lhs: JSStringKey, rhs: JSStringKey) -> Bool {
        jsStringEqual(lhs.string, rhs.string)
    }

    func hash(into hasher: inout Hasher) {
        jsStringHash(string, into: &hasher)
    }
}
