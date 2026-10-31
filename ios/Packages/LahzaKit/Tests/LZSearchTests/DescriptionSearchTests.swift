import Foundation
import LZEmbedding
import LZIndex
import Synchronization
import Testing
@testable import LZSearch

/// A description against the photos' vectors: the table first, the text model otherwise, then calibrated scores.
struct DescriptionSearchTests {
    /// A text model that records what it was asked and answers the same vector (its model is nil: ``Present`` gives one).
    final class FakeEncoder: TextEncoder {
        let model: EmbeddingModel? = nil
        private let state = Mutex<[[String]]>([])
        var asked: [[String]] { state.withLock { $0 } }

        func embed(_ texts: [String]) async throws -> [Float] {
            state.withLock { $0.append(texts) }
            return [0, 1, 0]
        }

        func prewarm() async {}
        func release() async {}
        func timings() async -> (load: Duration?, encode: Duration?) { (nil, nil) }
    }

    static func table() throws -> ConceptTable {
        try ConceptTable(data: ConceptTable.encode(ConceptTable.Index(model: "m", revision: "r", dimension: 3, templates: ["a photo of {}.", "{}."],
                                                                      entries: [ConceptTable.Entry(name: "red", kind: .concept, phrase: "red")]),
                                                   vectors: [[1, 0, 0]]))
    }

    @Test func theTableAnswersFirstAndTheModelTheRest() async throws {
        let table = try Self.table()
        let found = try #require(try await DescriptionSearch.vector(for: "Red", table: table, encoder: nil))
        #expect(found.vector == [1, 0, 0] && found.source == .table("red"))
        #expect(try await DescriptionSearch.vector(for: "a red car", table: table, encoder: nil) == nil, "no text model, no vector")
    }

    @Test func theModelSeesTheTablesTemplates() async throws {
        struct Present: TextEncoder {
            let inner: FakeEncoder
            var model: EmbeddingModel? {
                try? JSONDecoder().decode(EmbeddingModel.self, from: Data("""
                    {"id": "m", "dimension": 3, "imageSize": 256, "textLength": 64, "padTokenID": 0, "eosTokenID": 1, "lowercase": true,
                     "logitScale": 1, "logitBias": 0, "imageModel": "i", "textModel": "t", "source": "s", "revision": "r", "license": "l", "weights": "w"}
                    """.utf8))
            }
            func embed(_ texts: [String]) async throws -> [Float] { try await inner.embed(texts) }
            func prewarm() async {}
            func release() async {}
            func timings() async -> (load: Duration?, encode: Duration?) { (nil, nil) }
        }
        let fake = FakeEncoder()
        let found = try #require(try await DescriptionSearch.vector(for: " a red car ", table: try Self.table(), encoder: Present(inner: fake)))
        #expect(found.source == .model && found.vector == [0, 1, 0])
        #expect(fake.asked == [["a photo of a red car.", "a red car."]])
    }

    @Test func scoresAreCalibratedOverTheReferencePhotos() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let store = try await VectorStore.open(database, modelID: "m", dimension: 3)
        // 100 photos near [0, 0, 1], and photo 101 along the query.
        var entries = (1...100).map { VectorEntry(assetID: Int64($0), vector: [Float($0 % 7) * 0.01, Float($0 % 5) * 0.01, 1]) }
        entries.append(VectorEntry(assetID: 101, vector: [1, 0, 0.1]))
        try await store.upsert(entries)
        let scores = try await DescriptionSearch.scores([1, 0, 0], store: store, reference: Set((1...80).map(Int64.init)))
        let top = scores.top(3)
        #expect(top.first?.assetID == 101 && (top.first?.z ?? 0) > 10)
        #expect(scores.count(atLeast: 3) == 1)
        // Fewer than 50 reference photos with a vector: all photos calibrate.
        let few = try await DescriptionSearch.scores([1, 0, 0], store: store, reference: [1, 2, 3])
        #expect(few.calibration != nil)
    }
}
