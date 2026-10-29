import LZCore
import Foundation

/// A billing step that stopped, with its user-facing copy as the description.
public enum BillingError: Error, Sendable, Equatable, LocalizedError {
    /// The configured key has the wrong prefix or characters.
    case sdkKeyMismatch
    /// The key changed after the SDK was configured.
    case storeSettingChanged
    /// The 20 s price deadline passed.
    case pricesTimedOut
    /// No usable SDK key while loading the price.
    case missingStoreForPrices
    /// No usable SDK key while purchasing or restoring.
    case missingStoreForAction
    /// The offer's product is no longer the full-library unlock.
    case unlockUnavailable

    public var message: String {
        switch self {
        case .sdkKeyMismatch: BillingCopy.sdkKeyMismatch
        case .storeSettingChanged: BillingCopy.storeSettingChanged
        case .pricesTimedOut: BillingCopy.pricesTimedOut
        case .missingStoreForPrices: BillingCopy.missingStoreForPrices
        case .missingStoreForAction: BillingCopy.missingStoreForAction
        case .unlockUnavailable: BillingCopy.unlockUnavailable
        }
    }

    public var errorDescription: String? { message }
}

/// The copy for a store failure: the error's own description, except that provider and
/// configuration failures read as "The App Store is unavailable right now…".
public enum StoreMessage {
    /// The copy for any thrown value.
    public static func text(for error: any Error) -> String {
        map((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// A case-insensitive match of `revenuecat|rev\.cat|app store connect|configuration|offerings|products.*fetch`
    /// in `detail` → the unavailable copy, else `detail` unchanged.
    public static func map(_ detail: String) -> String {
        matchesProviderFailure(detail) ? BillingCopy.storeUnavailable : detail
    }

    /// That pattern: case folding covers only ASCII letters (a non-ASCII character never folds to
    /// ASCII), and `.*` does not cross a line terminator (LF, CR, U+2028, U+2029; not U+0085).
    public static func matchesProviderFailure(_ detail: String) -> Bool {
        let units = detail.utf16.map { unit -> UInt16 in
            (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
        }
        for literal in ["revenuecat", "rev.cat", "app store connect", "configuration", "offerings"] where contains(units, Array(literal.utf16)) {
            return true
        }
        let products = Array("products".utf16)
        let fetch = Array("fetch".utf16)
        var index = 0
        while let start = firstIndex(of: products, in: units, from: index) {
            var cursor = start + products.count
            while cursor + fetch.count <= units.count {
                if Array(units[cursor..<(cursor + fetch.count)]) == fetch { return true }
                if isLineTerminator(units[cursor]) { break }
                cursor += 1
            }
            index = start + 1
        }
        return false
    }

    private static func isLineTerminator(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    private static func contains(_ haystack: [UInt16], _ needle: [UInt16]) -> Bool {
        firstIndex(of: needle, in: haystack, from: 0) != nil
    }

    private static func firstIndex(of needle: [UInt16], in haystack: [UInt16], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, start <= haystack.count - needle.count else { return nil }
        for offset in start...(haystack.count - needle.count) where haystack[offset] == needle[0] {
            if Array(haystack[offset..<(offset + needle.count)]) == needle { return offset }
        }
        return nil
    }
}
