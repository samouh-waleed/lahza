import Foundation
import Synchronization

/// Small synchronous string key-value storage.
///
/// Values are raw strings: JSON text for structured values (use ``value(_:forKey:)`` /
/// ``setValue(_:forKey:)``), plain strings for a few rows. Never secrets (Keychain) and never the
/// corpus. Implementations must be thread-safe. Keys are built with ``KVKey``.
public protocol KeyValueStore: Sendable {
    /// The stored string, or nil.
    func string(forKey key: String) -> String?
    /// Stores a string.
    func setString(_ value: String, forKey key: String)
    /// Removes a key (no-op when absent).
    func removeValue(forKey key: String)
    /// Every stored key that starts with `prefix`, sorted.
    func keys(withPrefix prefix: String) -> [String]
}

extension KeyValueStore {
    /// Decodes the stored JSON as `T` with `JSONDecoder`; nil when missing, unparseable or
    /// mismatched.
    public func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let raw = string(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: Data(raw.utf8))
    }

    /// Encodes with `JSONEncoder` (sorted keys, slashes unescaped, so equal values store equal
    /// text) and stores the JSON. Returns false (and writes nothing) when encoding throws.
    @discardableResult
    public func setValue<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return false }
        setString(String(decoding: data, as: UTF8.self), forKey: key)
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
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

/// Thread-safe in-memory store for tests and previews.
public final class InMemoryKeyValueStore: KeyValueStore {
    private let storage: Mutex<[String: String]>

    public init(_ initial: [String: String] = [:]) {
        storage = Mutex(initial)
    }

    public func string(forKey key: String) -> String? { storage.withLock { $0[key] } }
    public func setString(_ value: String, forKey key: String) { storage.withLock { $0[key] = value } }
    public func removeValue(forKey key: String) { _ = storage.withLock { $0.removeValue(forKey: key) } }

    public func keys(withPrefix prefix: String) -> [String] {
        storage.withLock { rows in rows.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }

    /// Every stored pair (tests).
    public var snapshot: [String: String] { storage.withLock { $0 } }
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
