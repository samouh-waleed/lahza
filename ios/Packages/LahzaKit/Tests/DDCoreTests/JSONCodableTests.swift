import Foundation
import Testing
@testable import DDCore

@Suite("Codable bridging")
struct JSONCodableTests {
    struct Entry: Codable, Equatable {
        var id: String
        var kind: String
        var entryKey: String
        var data: JSONValue
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?
        var revision: Int?
        var _legacyImport: Bool?
    }

    @Test("Encoder keeps declaration order and matches JSON.stringify of the same JS literal")
    func encoderOrder() throws {
        let stamp = Date(jsMilliseconds: 1_790_238_600_000)
        let entry = Entry(
            id: "3f2b8c1e-9d4a-4b7e-8f21-0c5d6e7f8a9b", kind: "activity", entryKey: "moment:2026-09-24",
            data: ["type": "moment", "item_id": "m1"], createdAt: stamp, updatedAt: stamp,
            deletedAt: nil, revision: nil, _legacyImport: true
        )
        let json = try JSONValue.jsStringify(entry)
        // Synthesized encodeIfPresent omits nil like JS `undefined`; Dates are toISOString().
        #expect(json == #"{"id":"3f2b8c1e-9d4a-4b7e-8f21-0c5d6e7f8a9b","kind":"activity","entryKey":"moment:2026-09-24","data":{"type":"moment","item_id":"m1"},"createdAt":"2026-09-24T08:30:00.000Z","updatedAt":"2026-09-24T08:30:00.000Z","_legacyImport":true}"#)
        let decoded = try JSONValue.decode(Entry.self, fromJSON: json)
        #expect(decoded == entry)
    }

    @Test("Decoder exposes keys in source order and is exact about integers")
    func decoder() throws {
        struct Keys: Decodable {
            let order: [String]
            init(from decoder: any Decoder) throws {
                order = try decoder.container(keyedBy: _JSONCodingKey.self).allKeys.map(\.stringValue)
            }
        }
        let keys = try JSONValue.decode(Keys.self, fromJSON: #"{"z":1,"a":2,"m":3}"#)
        #expect(keys.order == ["z", "a", "m"])
        #expect(try JSONValue.decode(Int.self, fromJSON: "42") == 42)
        #expect(throws: DecodingError.self) { try JSONValue.decode(Int.self, fromJSON: "2.5") }
        #expect(throws: DecodingError.self) { try JSONValue.decode(UInt8.self, fromJSON: "256") }
        #expect(throws: DecodingError.self) { try JSONValue.decode(String.self, fromJSON: "1") }
        #expect(throws: DecodingError.self) { try JSONValue.decode(Bool.self, fromJSON: "0") }
        #expect(try JSONValue.decode([Int?].self, fromJSON: "[1,null,3]") == [1, nil, 3])
        #expect(try JSONValue.decode([String: Int].self, fromJSON: #"{"a":1}"#) == ["a": 1])
        #expect(try JSONValue.decode(Date.self, fromJSON: "0") == Date(jsMilliseconds: 0))
        #expect(try JSONValue.decode(Date.self, fromJSON: #""2026-09-24T08:30:00Z""#) == Date(jsMilliseconds: 1_790_238_600_000))
        #expect(throws: DecodingError.self) { try JSONValue.decode(Date.self, fromJSON: #""soon""#) }
        #expect(try JSONValue.decode(JSONValue?.self, fromJSON: "null") == nil)
        #expect(try JSONValue.decode(JSONValue.self, fromJSON: "null") == .null)
    }

    @Test("JSONValue survives both our coders with order, and Foundation's coders semantically")
    func roundTrips() throws {
        let value = try JSONValue.parse(#"{"b":[1,2.5,null,true,"x/y"],"a":{"2":"two","1":"one"},"c":-0}"#)
        let viaOurs = try JSONValueDecoder().decode(JSONValue.self, from: JSONValueEncoder().encode(value))
        #expect(viaOurs.jsStringify() == value.jsStringify())

        struct Wrapper: Codable { let payload: JSONValue; let object: JSONObject }
        let wrapper = Wrapper(payload: value, object: try #require(value["a"]?.objectValue))
        let encoded = try JSONValue(encoding: wrapper)
        #expect(encoded.jsStringify() == #"{"payload":{"b":[1,2.5,null,true,"x/y"],"a":{"1":"one","2":"two"},"c":0},"object":{"1":"one","2":"two"}}"#)

        let foundation = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(foundation == value)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(JSONObject.self, from: Data("[1]".utf8)) }
    }

    @Test("Nested containers, super encoders and special types")
    func containers() throws {
        struct Custom: Codable, Equatable {
            let url: URL
            let data: Data
            let small: Float
            let big: UInt64
            let decimal: Decimal
        }
        let url = try #require(URL(string: "https://example.com/privacy"))
        let custom = Custom(url: url, data: Data([1, 2, 3]), small: 0.5, big: 42, decimal: 1.25)
        let json = try JSONValue.jsStringify(custom)
        #expect(json == #"{"url":"https://example.com/privacy","data":"AQID","small":0.5,"big":42,"decimal":1.25}"#)
        #expect(try JSONValue.decode(Custom.self, fromJSON: json) == custom)

        struct Manual: Encodable {
            func encode(to encoder: any Encoder) throws {
                var outer = encoder.container(keyedBy: _JSONCodingKey.self)
                var list = outer.nestedUnkeyedContainer(forKey: _JSONCodingKey(stringValue: "list"))
                try list.encode(1)
                var inner = list.nestedContainer(keyedBy: _JSONCodingKey.self)
                try inner.encode("v", forKey: _JSONCodingKey(stringValue: "k"))
                try list.encodeNil()
                var nested = outer.nestedContainer(keyedBy: _JSONCodingKey.self, forKey: _JSONCodingKey(stringValue: "nested"))
                try nested.encode(true, forKey: _JSONCodingKey(stringValue: "flag"))
                let parent = outer.superEncoder()
                var single = parent.singleValueContainer()
                try single.encode("base")
            }
        }
        #expect(try JSONValue.jsStringify(Manual()) == #"{"list":[1,{"k":"v"},null],"nested":{"flag":true},"super":"base"}"#)
    }

    struct Reading: Codable, Equatable {
        var fontScale: Double
        var deletedAt: Date?
        var revision: Int?
        var note: String?
    }

    @Test("NilEncoding.null writes explicit nulls in declaration order")
    func explicitNulls() throws {
        let reading = Reading(fontScale: 1.6, deletedAt: nil, revision: nil, note: nil)
        #expect(try JSONValue.jsStringify(reading) == #"{"fontScale":1.6}"#)
        #expect(try JSONValue.jsStringify(reading, nilEncoding: .null) == #"{"fontScale":1.6,"deletedAt":null,"revision":null,"note":null}"#)
        let set = Reading(fontScale: 1, deletedAt: Date(jsMilliseconds: 0), revision: 3, note: "n")
        #expect(try JSONValue.jsStringify(set, nilEncoding: .null) == #"{"fontScale":1,"deletedAt":"1970-01-01T00:00:00.000Z","revision":3,"note":"n"}"#)
        #expect(try JSONValue.decode(Reading.self, fromJSON: #"{"fontScale":1.6,"deletedAt":null,"revision":null,"note":null}"#) == reading)

        // Every primitive overload of encodeIfPresent honours the option.
        struct All: Encodable {
            var b: Bool?; var s: String?; var d: Double?; var f: Float?
            var i: Int?; var i8: Int8?; var i16: Int16?; var i32: Int32?; var i64: Int64?
            var u: UInt?; var u8: UInt8?; var u16: UInt16?; var u32: UInt32?; var u64: UInt64?
            var nested: Reading?
        }
        let nulls = try JSONValueEncoder(nilEncoding: .null).encode(All())
        #expect(nulls.objectValue?.count == 15)
        #expect(nulls.objectValue?.values.allSatisfy(\.isNull) == true)
        #expect(try JSONValueEncoder().encode(All()) == [:])
        // Nested structs inherit the option; arrays of optionals always hold null.
        struct Outer: Encodable { var inner: Reading; var list: [Int?] }
        let outer = Outer(inner: reading, list: [1, nil])
        #expect(try JSONValue.jsStringify(outer) == #"{"inner":{"fontScale":1.6},"list":[1,null]}"#)
        #expect(try JSONValue.jsStringify(outer, nilEncoding: .null) == #"{"inner":{"fontScale":1.6,"deletedAt":null,"revision":null,"note":null},"list":[1,null]}"#)
    }

    @Test("@ExplicitNull writes null per property with both coders and decodes a missing key as nil")
    func explicitNullWrapper() throws {
        struct PushRecord: Codable, Equatable {
            var id: String
            @ExplicitNull var baseRevision: Int?
            @ExplicitNull var deletedAt: String?
            var optionalNote: String?
        }
        let record = PushRecord(id: "a", baseRevision: nil, deletedAt: nil, optionalNote: nil)
        #expect(try JSONValue.jsStringify(record) == #"{"id":"a","baseRevision":null,"deletedAt":null}"#)
        let foundation = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        #expect(foundation?["baseRevision"] is NSNull && foundation?["deletedAt"] is NSNull)
        #expect(foundation?["optionalNote"] == nil)

        let filled = PushRecord(id: "a", baseRevision: 7, deletedAt: "2026-09-24T08:30:00.000Z", optionalNote: "x")
        #expect(try JSONValue.jsStringify(filled) == #"{"id":"a","baseRevision":7,"deletedAt":"2026-09-24T08:30:00.000Z","optionalNote":"x"}"#)
        #expect(try JSONValue.decode(PushRecord.self, fromJSON: #"{"id":"a"}"#) == record)
        #expect(try JSONValue.decode(PushRecord.self, fromJSON: #"{"id":"a","baseRevision":null,"deletedAt":null}"#) == record)
        #expect(try JSONValue.decode(PushRecord.self, fromJSON: try JSONValue.jsStringify(filled)) == filled)
        #expect(try JSONDecoder().decode(PushRecord.self, from: Data(#"{"id":"a"}"#.utf8)) == record)
    }

    @Test("Float encodes through its shortest decimal, like Foundation's JSONEncoder")
    func floats() throws {
        struct Scales: Codable, Equatable { var fontScale: Float; var arabicScale: Float; var list: [Float] }
        let scales = Scales(fontScale: 1.6, arabicScale: 0.9, list: [0.1, 1.15, 3.3325, -0.0, 16_777_216])
        let json = try JSONValue.jsStringify(scales)
        #expect(json == #"{"fontScale":1.6,"arabicScale":0.9,"list":[0.1,1.15,3.3325,0,16777216]}"#)
        #expect(try JSONValue.decode(Scales.self, fromJSON: json) == scales)
        #expect(try JSONValue(encoding: Float(1.6)) == 1.6)
        #expect(try JSONValue(encoding: Float.greatestFiniteMagnitude).numberValue == 3.4028235e38)
        #expect(try JSONValue(encoding: Float.infinity).jsStringify() == "null")
        // Foundation's JSONEncoder prints the same digits.
        let foundation = try #require(String(data: try JSONEncoder().encode([Float(1.6), Float(0.9)]), encoding: .utf8))
        #expect(foundation == "[1.6,0.9]")
    }

    @Test("Settable key and dotted-path subscripts")
    func mutation() throws {
        var settings: JSONValue = ["location": ["lat": 1, "lng": 2], "search": ["filters": ["recent"]]]
        settings["search"] = ["filters": ["people"]]
        settings["map"] = ["enabled": false]
        #expect(settings.jsStringify() == #"{"location":{"lat":1,"lng":2},"search":{"filters":["people"]},"map":{"enabled":false}}"#)
        settings["map"] = nil
        #expect(settings.objectValue?.keys == ["location", "search"])

        #expect(settings[path: "location.lat"] == 1)
        #expect(settings[path: "location.missing"] == nil)
        #expect(settings[path: "search.filters.0"] == nil)  // arrays are not plain objects
        settings[path: "location.lat"] = 40.71427
        settings[path: "location.city.label"] = "New York"
        settings[path: "appearance.reducedMotion"] = nil
        settings[path: "search.filters"] = ["a", "b"]
        #expect(settings.jsStringify() == #"{"location":{"lat":40.71427,"lng":2,"city":{"label":"New York"}},"search":{"filters":["a","b"]},"appearance":{}}"#)
        // A non-object on the way is replaced by {}.
        settings[path: "search.filters.first"] = true
        #expect(settings[path: "search.filters"] == ["first": true])
        var scalar: JSONValue = 5
        scalar["a"] = 1
        #expect(scalar == ["a": 1])
        var untouched: JSONValue = 5
        untouched["a"] = nil
        #expect(untouched == 5)
        #expect(JSONValue.pathSegments("a..b") == ["a", "", "b"])
        #expect(JSONValue.pathSegments("") == [""])
    }
}
