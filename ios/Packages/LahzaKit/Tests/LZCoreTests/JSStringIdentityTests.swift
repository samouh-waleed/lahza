import Foundation
import Testing
@testable import LZCore

/// JS compares strings by UTF-16 code units; Swift `String` uses canonical equivalence. Every
/// LZCore comparison that stands in for JS must follow JS.
@Suite("JS string identity (code units, no normalization)")
struct JSStringIdentityTests {
    @Test("Keys that differ only by normalization are distinct object members, as in JS")
    func distinctKeys() throws {
        let nfc = "\u{E9}", nfd = "e\u{301}"
        #expect(nfc == nfd)  // Swift's own String equality: the reason for this suite
        #expect(!jsStringEqual(nfc, nfd))

        let parsed = try JSONValue.parse(#"{"é":1,"é":2,"K":3,"K":4}"#)
        let object = try #require(parsed.objectValue)
        #expect(object.count == 4)
        #expect(object[nfc] == 1 && object[nfd] == 2)
        #expect(object["K"] == 3 && object["\u{212A}"] == 4)
        #expect(parsed.jsStringify() == "{\"\u{E9}\":1,\"e\u{301}\":2,\"K\":3,\"\u{212A}\":4}")

        var edited = object
        edited[nfd] = nil
        #expect(edited.keys == [nfc, "K", "\u{212A}"])
        #expect(edited.contains(nfc) && !edited.contains(nfd))

        // Equality and hashing are code-unit exact too.
        #expect(JSONValue.object([nfc: 1]) != JSONValue.object([nfd: 1]))
        #expect(Set<JSONValue>([.string(nfc), .string(nfd), .string(nfc)]).count == 2)
        let arabicA = "\u{628}\u{651}\u{64E}", arabicB = "\u{628}\u{64E}\u{651}"
        #expect(arabicA == arabicB)
        #expect(JSONValue.string(arabicA) != JSONValue.string(arabicB))
    }

    @Test("deepMerge treats normalization variants as different keys")
    func deepMerge() throws {
        let merged = JSONValue.deepMerge(["\u{E9}": ["x": 1]], ["e\u{301}": ["y": 2]])
        #expect(merged.jsStringify() == "{\"\u{E9}\":{\"x\":1},\"e\u{301}\":{\"y\":2}}")
    }

    @Test("Encoder keys are code-unit exact")
    func encoderKeys() throws {
        struct Keys: Encodable {
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: _JSONCodingKey.self)
                try container.encode(1, forKey: _JSONCodingKey(stringValue: "\u{E9}"))
                try container.encode(2, forKey: _JSONCodingKey(stringValue: "e\u{301}"))
            }
        }
        #expect(try JSONValue.jsStringify(Keys()) == "{\"\u{E9}\":1,\"e\u{301}\":2}")
    }

    @Test("kv prefixes compare code units, like UserDefaults keys and JS startsWith")
    func kvPrefixes() {
        let store = InMemoryKeyValueStore()
        store.setString("1", forKey: "lahza.u.\u{E9}.settings-cache.v1")
        store.setString("2", forKey: "lahza.u.e\u{301}.settings-cache.v1")
        store.setString("3", forKey: "lahza.u.e\u{301}x.settings-cache.v1")
        #expect(store.keys(withPrefix: "lahza.u.").count == 3)
        #expect(store.keys(withPrefix: "lahza.u.e\u{301}.") == ["lahza.u.e\u{301}.settings-cache.v1"])
        #expect(store.string(forKey: "lahza.u.\u{E9}.settings-cache.v1") == "1")
        #expect(store.removeValues(withPrefix: "lahza.u.\u{E9}.") == 1)
        #expect(store.string(forKey: "lahza.u.e\u{301}.settings-cache.v1") == "2")
        // A grapheme-based hasPrefix would say "e" + U+0301 does not start with "e"; JS says it does.
        #expect(store.keys(withPrefix: "lahza.u.e").count == 2)
    }
}
