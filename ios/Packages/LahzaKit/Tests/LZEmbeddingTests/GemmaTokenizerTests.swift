import Foundation
import Testing
@testable import LZEmbedding

/// Our own Gemma tokenizer (decision 41): the BPE rules on a tiny vocabulary, the exact JSON reader the vocabulary
/// builder uses, and, with SigLIP 2's real vocabulary (`LZ_VOCAB`, set by `make test-kit` once `make tokenizer` built
/// it), the ids Python's `tokenizers` gives for 216 strings and for the conversion's own prompts.
struct GemmaTokenizerTests {
    /// Pieces: <pad>=0 <eos>=1 <unk>=2, single scalars, three bytes, and merges h+e → he (rank 0), he+l → hel (1),
    /// l+l → ll (2), ▁+h → ▁h (3), hel+lo → hello… built so the merge order matters.
    static func tiny() throws -> GemmaTokenizer {
        let pieces: [String: Int32] = ["h": 10, "e": 11, "l": 12, "o": 13, "▁": 14, "he": 20, "hel": 21, "ll": 22, "▁h": 23, "lo": 24, "hello": 25,
                                       "a": 30, "b": 31]
        let merges: [(String, String)] = [("h", "e"), ("he", "l"), ("l", "l"), ("▁", "h"), ("l", "o"), ("hel", "lo")]
        var scalars: [UInt32: Int32] = [:]
        for (piece, id) in pieces where piece.unicodeScalars.count == 1 { scalars[piece.unicodeScalars.first!.value] = id }
        let data = TokenizerVocabulary.encode(scalars: scalars, bytes: [0xF0: 40, 0x9F: 41, 0x8E: 42, 0x89: 43],
                                              merges: merges.map { (pieces[$0.0]!, pieces[$0.1]!, pieces[$0.0 + $0.1]!) },
                                              added: [("<eos>", 1), ("<b>", 50), ("<bb>", 51), ("\n", 52)], eos: 1, pad: 0, unk: 2)
        return GemmaTokenizer(vocabulary: try TokenizerVocabulary(data: data))
    }

    @Test func theLowestRankMergesFirst() throws {
        let tokenizer = try Self.tiny()
        // h e l l o: he (0), then hel (1) beats ll (2) and lo (4); then hel+lo needs lo: l+o (4); then hello (5).
        #expect(tokenizer.encode("hello") == [25, 1])
        #expect(tokenizer.encode("HELLO") == [25, 1], "lowercased first")
        #expect(tokenizer.encode("hell") == [21, 12, 1], "hel, then l alone")
        #expect(tokenizer.encode("lll") == [22, 12, 1], "the leftmost pair merges first")
    }

    @Test func spacesBecomeMarksWithNoneBeforeTheFirstWord() throws {
        let tokenizer = try Self.tiny()
        #expect(tokenizer.encode("he he") == [20, 14, 20, 1], "h+e merges at both places before ▁+h can; no ▁ before the first word")
        #expect(tokenizer.encode(" a") == [14, 30, 1])
        #expect(tokenizer.encode("") == [1])
    }

    @Test func aScalarWithoutAPieceFallsBackToItsBytes() throws {
        let tokenizer = try Self.tiny()
        #expect(tokenizer.encode("a🎉b") == [30, 40, 41, 42, 43, 31, 1], "🎉 is F0 9F 8E 89")
        #expect(tokenizer.encode("a€€b") == [30, 2, 31, 1], "bytes the vocabulary lacks are one unknown")
    }

    @Test func addedTokensStayWholeLongestFirst() throws {
        let tokenizer = try Self.tiny()
        #expect(tokenizer.encode("a<b>b") == [30, 50, 31, 1])
        #expect(tokenizer.encode("<bb>") == [51, 1])
        #expect(tokenizer.encode("a\nb") == [30, 52, 31, 1], "no ▁ after an added token either")
        #expect(tokenizer.encode("<eos>") == [1, 1])
    }

    @Test func aLimitKeepsTheEnd() throws {
        let tokenizer = try Self.tiny()
        let ids = tokenizer.encode(String(repeating: "a ", count: 100), limit: 64)
        #expect(ids.count == 64 && ids.last == 1)
        #expect(tokenizer.encode("a", limit: 64) == [30, 1])
    }

    @Test func theVocabularyFileRoundTrips() throws {
        let vocabulary = try Self.tiny().vocabulary
        #expect(vocabulary.eos == 1 && vocabulary.pad == 0 && vocabulary.unk == 2 && vocabulary.mergeCount == 6)
        #expect(vocabulary.merge(10, 11)?.rank == 0 && vocabulary.merge(10, 11)?.merged == 20)
        #expect(vocabulary.merge(11, 10) == nil)
        #expect(vocabulary.id(ofScalar: 0x2581) == 14 && vocabulary.id(ofScalar: 0x7A) == nil)
        #expect(vocabulary.id(ofByte: 0xF0) == 40 && vocabulary.id(ofByte: 0) == nil)
        #expect(throws: EmbeddingError.unexpectedOutput) { try TokenizerVocabulary(data: Data("nope".utf8)) }
    }

    // MARK: Building from tokenizer.json

    @Test func theBuilderKeepsCanonicallyEqualPiecesApart() throws {
        // "é" as one scalar (00E9) and as e + combining acute (0065 0301): two pieces, two ids.
        let json = #"""
            {"added_tokens": [{"id": 0, "content": "<pad>"}, {"id": 1, "content": "<eos>"}, {"id": 2, "content": "<unk>"}],
             "model": {"type": "BPE", "vocab": {"<pad>": 0, "<eos>": 1, "<unk>": 2, "é": 3, "e": 4, "́": 5, "é": 6, "<0x41>": 7,
                                                "🎉": 8, "x": 9, "xx": 10},
                       "merges": [["e", "́"], "x x"]}}
            """#
        let vocabulary = try TokenizerVocabulary(data: try TokenizerVocabulary.build(fromTokenizerJSON: Data(json.utf8)))
        #expect(vocabulary.id(ofScalar: 0xE9) == 3 && vocabulary.id(ofScalar: 0x65) == 4)
        #expect(vocabulary.merge(4, 5)?.merged == 6 && vocabulary.merge(9, 9)?.merged == 10)
        #expect(vocabulary.id(ofByte: 0x41) == 7)
        #expect(vocabulary.id(ofScalar: 0x1F389) == 8, "a surrogate pair is one scalar")
        let tokenizer = GemmaTokenizer(vocabulary: vocabulary)
        #expect(tokenizer.encode("\u{e9}") == [3, 1] && tokenizer.encode("e\u{301}") == [6, 1])
    }

    @Test func theExactJSONReaderReadsEscapesAndKeepsKeys() throws {
        var reader = ExactJSON(Data(#"{"a": [1, -2.5e1, true, false, null, "t\"\\\/\nA"], "a": {}, "é": []}"#.utf8))
        guard case .object(let members) = try reader.value() else {
            Issue.record("not an object")
            return
        }
        #expect(members.count == 3, "a repeated key is kept")
        guard case .array(let values)? = members[key: "a"], case .string(let text) = values[5], case .number(let number) = values[1] else {
            Issue.record("not read")
            return
        }
        #expect(number == -25)
        #expect(text == "t\"\\/\nA".unicodeScalars.map(\.value))
        #expect(members[2].key == [0xE9])
    }

    // MARK: SigLIP 2's vocabulary

    struct Golden: Decodable {
        struct Case: Decodable {
            var text: String
            var ids: [Int32]
        }

        var cases: [Case]
    }

    static var vocabularyURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["LZ_VOCAB"], environment["LZ_MODEL_DIR"].map { $0 + "/" + TokenizerVocabulary.fileName }]
        return candidates.compactMap { $0 }.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test(.enabled(if: vocabularyURL != nil, "needs SigLIP 2's vocabulary: make tokenizer"))
    func everyGoldenStringGivesPythonsIDs() throws {
        let tokenizer = GemmaTokenizer(vocabulary: try TokenizerVocabulary.load(try #require(Self.vocabularyURL)))
        let url = try #require(Bundle.module.url(forResource: "TokenizerGolden", withExtension: "json"))
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        #expect(golden.cases.count > 200)
        var wrong = 0
        for item in golden.cases {
            let ids = tokenizer.encode(item.text)
            if ids != item.ids {
                wrong += 1
                Issue.record("“\(item.text.debugDescription)”: \(ids) ≠ \(item.ids)")
            }
        }
        #expect(wrong == 0)
    }

    @Test(.enabled(if: vocabularyURL != nil && ModelFolder.isAvailable, "needs the converted model and its vocabulary"))
    func theConversionsPromptsGiveItsIDs() throws {
        let tokenizer = GemmaTokenizer(vocabulary: try TokenizerVocabulary.load(try #require(Self.vocabularyURL)))
        for prompt in try ModelFolder.parity().prompts {
            #expect(tokenizer.encode(prompt.text) == ModelFolder.unpadded(prompt.tokenIDs, pad: 0), "\(prompt.text)")
        }
    }
}
