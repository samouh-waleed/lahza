import Foundation
import Testing
@testable import LZCore

@Suite("KV storage and key builders")
struct KeyValueStoreTests {
    @Test("Lahza's named keys")
    func namedKeys() {
        #expect(KVKey.storage("x") == "lahza.x")
        #expect(KVKey.device(KVSuffix.onboardingCompleted) == "lahza.onboarding.completed.v1")
        #expect(KVKey.device(KVSuffix.appearance) == "lahza.appearance.mode.v1")
        #expect(KVKey.device(KVSuffix.entitlementCache) == "lahza.billing.entitlement.v1")
    }

    private func exercise(_ store: any KeyValueStore) throws {
        // Codable values round-trip through compact JSON text; nil optionals are left out.
        struct Banner: Codable, Equatable { let at: Int64; let path: String; let note: String? }
        let banner = Banner(at: 1_727_136_000_123, path: "a/b", note: nil)
        #expect(store.setValue(banner, forKey: "lahza.banner.v1"))
        #expect(store.string(forKey: "lahza.banner.v1") == #"{"at":1727136000123,"path":"a/b"}"#)
        #expect(store.value(Banner.self, forKey: "lahza.banner.v1") == banner)
        // Keys are sorted, so equal values always store equal text.
        struct Reversed: Codable { let z: Int; let a: Int }
        #expect(store.setValue(Reversed(z: 1, a: 2), forKey: "lahza.sorted"))
        #expect(store.string(forKey: "lahza.sorted") == #"{"a":2,"z":1}"#)
        // Dates (to the full Double), nested values, non-ASCII text and a stored null round-trip.
        struct Stamp: Codable, Equatable { let at: Date; let tags: [String]; let scales: [String: Double] }
        let stamp = Stamp(at: Date(timeIntervalSince1970: 1_790_238_600.123_456), tags: ["x", "\u{E9}", "\u{628}"], scales: ["k": 1.6])
        #expect(store.setValue(stamp, forKey: "lahza.stamp"))
        #expect(store.value(Stamp.self, forKey: "lahza.stamp") == stamp)
        #expect(store.setValue(Int?.none, forKey: "lahza.null"))
        #expect(store.string(forKey: "lahza.null") == "null")
        #expect(store.value(Int?.self, forKey: "lahza.null") == .some(nil))
        // Unparseable text, a type mismatch and missing keys read as nil.
        store.setString("{not json", forKey: "lahza.broken")
        #expect(store.value(Banner.self, forKey: "lahza.broken") == nil)
        #expect(store.value(Int.self, forKey: "lahza.banner.v1") == nil)
        #expect(store.value(Banner.self, forKey: "lahza.missing") == nil)
        // A value JSON cannot hold writes nothing.
        #expect(!store.setValue(Double.nan, forKey: "lahza.nan"))
        #expect(store.string(forKey: "lahza.nan") == nil)

        // Prefix queries are sorted; prefix removal leaves other rows.
        store.setString("1", forKey: "lahza.index.b")
        store.setString("1", forKey: "lahza.index.a")
        store.setString("1", forKey: "lahza.indexer.c")
        #expect(store.keys(withPrefix: "lahza.index") == ["lahza.index.a", "lahza.index.b", "lahza.indexer.c"])
        #expect(store.removeValues(withPrefix: "lahza.index.") == 2)
        #expect(store.keys(withPrefix: "lahza.index.").isEmpty)
        #expect(store.string(forKey: "lahza.indexer.c") == "1")

        store.removeValue(forKey: "lahza.banner.v1")
        #expect(store.string(forKey: "lahza.banner.v1") == nil)
    }

    @Test("In-memory store")
    func inMemory() throws {
        let store = InMemoryKeyValueStore()
        try exercise(store)
        #expect(store.snapshot["lahza.broken"] == "{not json")
    }

    /// One fixed suite (cleared before and after) so runs do not leave a new plist in
    /// ~/Library/Preferences each time.
    @Test("UserDefaults suite store")
    func userDefaults() throws {
        let suite = "com.waleedsamouh.lahza.tests.kv"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = try #require(UserDefaultsKeyValueStore(suiteName: suite))
        try exercise(store)
        #expect(store.keys(withPrefix: "lahza.").contains("lahza.broken"))
    }

    @Test("In-memory store is safe under concurrent writers")
    func concurrency() async {
        let store = InMemoryKeyValueStore()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { store.setValue(index, forKey: "lahza.k.\(index)") }
            }
        }
        #expect(store.keys(withPrefix: "lahza.k.").count == 100)
        #expect(store.value(Int.self, forKey: "lahza.k.42") == 42)
    }
}
