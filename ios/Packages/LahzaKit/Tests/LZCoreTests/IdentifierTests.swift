import Foundation
import Testing
@testable import LZCore

@Suite("Identifiers")
struct IdentifierTests {
    @Test("activityId is deterministic, UUID-shaped and stable across releases")
    func activityIdIsStable() {
        // Pinned values: ids already written must keep matching, so these bytes must never change.
        #expect(activityId(owner: "device", collection: "photos", kind: "moment", key: "2024-06-01") == "90030dfd-a8d6-5746-9493-aa03bbf72780")
        #expect(activityId(owner: "o", collection: "c/d", kind: "k\"", key: "\u{E9}\u{1F600}") == "274cd6bc-050e-5c5b-be85-e6aef1519442")
        #expect(activityId(owner: "", collection: "", kind: "", key: "") == "695e6e3a-76ca-561b-8f75-de2833be5117")
        #expect(activityId(owner: "a\nb", collection: "tab\t", kind: "\u{1}", key: "\\") == "59dbc7c9-a9d9-5b7b-9fb2-c6fd6d84dd59")

        let id = activityId(owner: "device", collection: "photos", kind: "moment", key: "2024-06-01")
        #expect(id == activityId(owner: "device", collection: "photos", kind: "moment", key: "2024-06-01"))
        #expect(LowercaseUUID.isValid(id))
        // Each part counts, and moving text between parts gives a different id.
        #expect(id != activityId(owner: "device", collection: "photos", kind: "moment", key: "2024-06-02"))
        #expect(activityId(owner: "ab", collection: "c", kind: "k", key: "x") != activityId(owner: "a", collection: "bc", kind: "k", key: "x"))
    }

    @Test("The hashed natural key is compact JSON with slashes and non-ASCII text left as is")
    func naturalKeyBytes() {
        func text(_ parts: [String]) -> String { String(decoding: naturalKeyJSON(parts), as: UTF8.self) }
        #expect(text(["device", "photos", "moment", "2024-06-01"]) == #"["device","photos","moment","2024-06-01"]"#)
        #expect(text(["c/d", "q\"", "b\\", "\u{E9}\u{1F600}", "\u{2028}"]) == "[\"c/d\",\"q\\\"\",\"b\\\\\",\"\u{E9}\u{1F600}\",\"\u{2028}\"]")
        #expect(text(["\u{8}\u{C}\n\r\t", "\u{1}\u{1F}"]) == #"["\b\f\n\r\t","\u0001\u001f"]"#)
        #expect(sha256Hex(naturalKeyJSON(["device", "photos", "moment", "2024-06-01"])) == "90030dfda8d607465493aa03bbf72780e4f819ed8092ba7a4ef423232e4705c5")
    }
}
