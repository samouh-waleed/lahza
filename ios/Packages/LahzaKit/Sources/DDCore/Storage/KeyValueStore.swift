import Foundation
import Synchronization

/// Small synchronous string key-value storage.
///
/// Values are raw strings: JSON text for structured values (use ``json(forKey:)`` /
/// ``setJSON(_:forKey:)``), plain strings for a few rows. Never secrets (Keychain) and never the
/// corpus. Implementations must be thread-safe.
///
/// Keys are compared by code units, like `UserDefaults` (literal `NSString` comparison), never by
/// Unicode canonical equivalence.
public protocol KeyValueStore: Sendable {
    /// The stored string, or nil.
    func string(forKey key: String) -> String?
    /// Stores a string.
    func setString(_ value: String, forKey key: String)
    /// Removes a key (no-op when absent).
    func removeValue(forKey key: String)
    /// Every stored key that starts with `prefix`, compared by code units like JS `startsWith`.
    func keys(withPrefix prefix: String) -> [String]
}

extension KeyValueStore {
    /// The stored JSON parsed, or nil when missing or unparseable. A stored `null` comes back as
    /// `.null`.
    public func json(forKey key: String) -> JSONValue? {
        guard let raw = string(forKey: key) else { return nil }
        return try? JSONValue.parse(raw)
    }

    /// Stores `JSON.stringify(value)`.
    public func setJSON(_ value: JSONValue, forKey key: String) {
        setString(value.jsStringify(), forKey: key)
    }

    /// Decodes the stored JSON as `T`; nil when missing, unparseable or mismatched.
    public func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let json = json(forKey: key) else { return nil }
        return try? JSONValueDecoder().decode(type, from: json)
    }

    /// Encodes with ``JSONValueEncoder`` and stores the JS-exact JSON. Returns false
    /// (and writes nothing) when encoding throws.
    @discardableResult
    public func setValue<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        guard let json = try? JSONValueEncoder().encode(value) else { return false }
        setJSON(json, forKey: key)
        return true
    }

    /// Removes every key starting with `prefix` and returns how many.
    @discardableResult
    public func removeValues(withPrefix prefix: String) -> Int {
        let keys = keys(withPrefix: prefix)
        for key in keys { removeValue(forKey: key) }
        return keys.count
    }
}

/// `UserDefaults`-backed store (standard defaults or a suite such as the App Group).
public struct UserDefaultsKeyValueStore: KeyValueStore {
    // `UserDefaults` is not annotated Sendable, but Apple documents it as thread-safe ("you can
    // use it from multiple threads without additional synchronization"), and this reference is
    // immutable, so sharing it across isolation domains is sound.
    nonisolated(unsafe) private let defaults: UserDefaults

    /// Standard defaults (`suiteName == nil`) or the named suite. Nil when the suite name is
    /// invalid (for example the app's own bundle id).
    public init?(suiteName: String? = nil) {
        if let suiteName {
            guard let suite = UserDefaults(suiteName: suiteName) else { return nil }
            defaults = suite
        } else {
            defaults = .standard
        }
    }

    /// Wraps an existing `UserDefaults`.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func setString(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
    public func removeValue(forKey key: String) { defaults.removeObject(forKey: key) }

    public func keys(withPrefix prefix: String) -> [String] {
        storedKeys().filter { jsStringHasPrefix($0, prefix) }.sorted(by: jsStringLess)
    }

    /// Every key visible through these defaults. The Swift `dictionaryRepresentation()` bridges
    /// eagerly into a `[String: Any]`, which merges keys that are canonically equivalent (NFC and
    /// NFD spellings) and drops one at random, so the Objective-C dictionary's key array is read
    /// instead and each key is bridged on its own.
    private func storedKeys() -> [String] {
        let selector = NSSelectorFromString("dictionaryRepresentation")
        if defaults.responds(to: selector),
           let dictionary = defaults.perform(selector)?.takeUnretainedValue() as? NSDictionary {
            return dictionary.allKeys.compactMap { $0 as? String }
        }
        return Array(defaults.dictionaryRepresentation().keys)
    }
}

/// Thread-safe in-memory store for tests and previews. Keys are code-unit exact, like `UserDefaults`.
public final class InMemoryKeyValueStore: KeyValueStore {
    private let storage: Mutex<[JSStringKey: String]>

    public init(_ initial: [String: String] = [:]) {
        var rows: [JSStringKey: String] = [:]
        for (key, value) in initial { rows[JSStringKey(key)] = value }
        storage = Mutex(rows)
    }

    public func string(forKey key: String) -> String? { storage.withLock { $0[JSStringKey(key)] } }
    public func setString(_ value: String, forKey key: String) { storage.withLock { $0[JSStringKey(key)] = value } }
    public func removeValue(forKey key: String) { _ = storage.withLock { $0.removeValue(forKey: JSStringKey(key)) } }

    public func keys(withPrefix prefix: String) -> [String] {
        storage.withLock { rows in
            rows.keys.map(\.string).filter { jsStringHasPrefix($0, prefix) }.sorted(by: jsStringLess)
        }
    }

    /// Every stored pair (tests). Keys that differ only by Unicode normalization collapse in a
    /// Swift dictionary; use ``keys(withPrefix:)`` with `""` to see every stored key.
    public var snapshot: [String: String] {
        storage.withLock { rows in
            var copy: [String: String] = [:]
            for (key, value) in rows { copy[key.string] = value }
            return copy
        }
    }
}

/// Key builders for kv rows. Every row is `lahza.<suffix>`.
public enum KVKey {
    /// `lahza.<suffix>`.
    public static func storage(_ suffix: String) -> String {
        "\(Brand.storagePrefix).\(suffix)"
    }

    /// A device-wide row: `lahza.<suffix>`.
    public static func device(_ suffix: String) -> String {
        storage(suffix)
    }
}

/// kv row suffixes. Lahza keeps everything on this device; there are no account-scoped rows.
public enum KVSuffix {
    /// Set once onboarding has finished.
    public static let onboardingCompleted = "onboarding.completed.v1"
    /// Settings › Appearance: system, light or dark.
    public static let appearance = "appearance.mode.v1"
    /// The last entitlement RevenueCat reported, so an offline launch knows the unlock state.
    public static let entitlementCache = "billing.entitlement.v1"
}
