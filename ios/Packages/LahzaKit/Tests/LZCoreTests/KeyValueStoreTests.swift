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
        // JSON-exact text.
        store.setJSON(["at": 1_727_136_000_123, "path": "a/b"], forKey: "lahza.banner.v1")
        #expect(store.string(forKey: "lahza.banner.v1") == #"{"at":1727136000123,"path":"a/b"}"#)
        #expect(store.json(forKey: "lahza.banner.v1")?["at"] == 1_727_136_000_123)
        // A stored null reads back as null; unparseable text and missing keys read as nil.
        store.setJSON(.null, forKey: "lahza.null")
        #expect(store.json(forKey: "lahza.null") == .null)
        store.setString("{not json", forKey: "lahza.broken")
        #expect(store.json(forKey: "lahza.broken") == nil)
        #expect(store.json(forKey: "lahza.missing") == nil)

        // Codable helpers.
        struct Banner: Codable, Equatable { let at: Int64; let note: String? }
        #expect(store.setValue(Banner(at: 5, note: nil), forKey: "lahza.codable"))
        #expect(store.string(forKey: "lahza.codable") == #"{"at":5}"#)
        #expect(store.value(Banner.self, forKey: "lahza.codable") == Banner(at: 5, note: nil))
        #expect(store.value(Banner.self, forKey: "lahza.broken") == nil)

        // Prefix removal leaves other rows.
        store.setString("1", forKey: "lahza.index.a")
        store.setString("1", forKey: "lahza.index.b")
        store.setString("1", forKey: "lahza.indexer.c")
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
        // UserDefaults keys are literal (code-unit) strings, like the in-memory store.
        store.setString("1", forKey: "lahza.\u{E9}.x")
        store.setString("2", forKey: "lahza.e\u{301}.x")
        #expect(store.string(forKey: "lahza.\u{E9}.x") == "1")
        #expect(store.string(forKey: "lahza.e\u{301}.x") == "2")
        #expect(store.keys(withPrefix: "lahza.e\u{301}.") == ["lahza.e\u{301}.x"])
    }

    @Test("In-memory store is safe under concurrent writers")
    func concurrency() async {
        let store = InMemoryKeyValueStore()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { store.setJSON(.number(Double(index)), forKey: "lahza.k.\(index)") }
            }
        }
        #expect(store.keys(withPrefix: "lahza.k.").count == 100)
    }
}
