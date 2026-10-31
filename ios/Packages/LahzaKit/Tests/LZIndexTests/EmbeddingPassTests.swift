import CoreGraphics
import Foundation
import GRDB
import LZCore
import LZEmbedding
import LZGeo
import LZLibrary
import Synchronization
import Testing
@testable import LZIndex

/// P1b, the embedding pass inside the Vision queue: turning the model on fills only the photos without a vector, the
/// reference sample goes first, edits, deletions, a new vector file and CPU-made vectors, and what it reports.
@Suite struct EmbeddingPassTests {
    static let manifest = """
        {"id": "fake-8", "dimension": 8, "imageSize": 256, "textLength": 64, "padTokenID": 0, "eosTokenID": 1, "lowercase": true,
         "logitScale": 112.0, "logitBias": -16.5, "imageModel": "Image.mlmodelc", "textModel": "Text.mlmodelc", "source": "test",
         "revision": "1", "license": "Apache-2.0", "weights": "none"}
        """

    static func model(id: String = "fake-8") -> EmbeddingModel {
        var model = try! JSONDecoder().decode(EmbeddingModel.self, from: Data(manifest.utf8))
        model.id = id
        return model
    }

    /// A model that never loads Core ML; it counts loads and releases.
    final class FakeEmbedders: ImageEmbedderSource {
        let model: EmbeddingModel?
        private let state = Mutex<(loads: [ComputeMode], releases: Int)>(([], 0))

        init(model: EmbeddingModel? = EmbeddingPassTests.model()) {
            self.model = model
        }

        var loads: [ComputeMode] { state.withLock { $0.loads } }
        var releases: Int { state.withLock { $0.releases } }

        func embedder(_ mode: ComputeMode) async throws -> any ImageEmbedder {
            state.withLock { $0.loads.append(mode) }
            guard let model else { throw EmbeddingError.missingModel(EmbeddingModel.manifestName) }
            return FakeEmbedder(model: model, mode: mode)
        }

        func release() async { state.withLock { $0.releases += 1 } }

        func lastLoad() async -> Duration? { .milliseconds(5) }
    }

    struct FakeEmbedder: ImageEmbedder {
        let model: EmbeddingModel
        let mode: ComputeMode

        func embed(_ image: CGImage) async throws -> [Float] { [] }
    }

    /// Records each photo it was asked about, with or without tags and a model; a photo's vector is one-hot at its
    /// asset id (mod 8), so tests can tell vectors apart.
    final class Analyzer: VisualAnalyzer {
        struct Ask: Sendable, Hashable {
            var localID: String
            var tags: Bool
            var mode: ComputeMode?
        }

        private let state = Mutex<[Ask]>([])
        var asked: [Ask] { state.withLock { $0 } }
        /// The model gives no vector for these (it threw, or the image went).
        let noVector: Set<String>

        init(noVector: Set<String> = []) {
            self.noVector = noVector
        }

        func supportedLabels() async -> [String] { ["soccer"] }

        func analyze(_ asset: VisualAsset, tags: Bool, embedder: (any ImageEmbedder)?) async -> VisualOutcome {
            let mode = (embedder as? FakeEmbedder)?.mode
            state.withLock { $0.append(Ask(localID: asset.localID, tags: tags, mode: mode)) }
            var vector = [Float](repeating: 0, count: 8)
            vector[Int(asset.id % 8)] = 1
            if !tags, embedder != nil, noVector.contains(asset.localID) { return .failed }
            return .analysed(tags ? VisualAnalysis(labels: [VisualLabel(name: "soccer", confidence: 0.9, flags: [.precise])]) : nil,
                             vector: embedder == nil || noVector.contains(asset.localID) ? nil : vector)
        }
    }

    static let now = Int64(Fixture.now.timeIntervalSince1970)

    private func index(_ reader: FakeLibraryReader) async throws -> (IndexDatabase, LibraryIndexer, VectorIndex) {
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader)
        await Fixture.sync(indexer)
        return (database, indexer, VectorIndex(database: database))
    }

    private func queue(_ database: IndexDatabase, _ indexer: LibraryIndexer, _ analyzer: Analyzer, embedders: (any ImageEmbedderSource)?,
                       vectors: VectorIndex, referenceSize: Int = ReferenceSample.size, clock: any AppClock = FixedClock(Fixture.now)) -> VisualQueue {
        VisualQueue(database: database, analyzer: analyzer, embedders: embedders, vectors: vectors, clock: clock,
                    notify: { await indexer.enqueue(.restructure) },
                    policy: VisualPolicy(batchSize: 4, concurrency: 1, checkpointInterval: .zero, referenceSize: referenceSize))
    }

    /// `local_id` → (embed_version, embed_units).
    private func embedRows(_ database: IndexDatabase) async throws -> [String: (version: Int?, units: Int?)] {
        try await database.read { db in
            var rows: [String: (Int?, Int?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT a.local_id, v.embed_version, v.embed_units FROM asset_visual v JOIN asset a ON a.id = v.asset_id") {
                rows[row[0]] = (row[1], row[2])
            }
            return rows
        }
    }

    private func idByLocalID(_ database: IndexDatabase) async throws -> [String: Int64] {
        try await database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT local_id, id FROM asset").map { ($0[0] as String, $0[1] as Int64) })
        }
    }

    // MARK: Filling

    @Test func turningTheModelOnFillsOnlyTheMissingVectors() async throws {
        let reader = FakeLibraryReader(.explicit([Fixture.photo("a", Self.now), Fixture.photo("b", Self.now - 60), Fixture.photo("c", Self.now - 120)]))
        let (database, indexer, vectors) = try await index(reader)
        let analyzer = Analyzer()
        // Tags first, with no model on the iPhone.
        await queue(database, indexer, analyzer, embedders: nil, vectors: vectors).run()
        #expect(analyzer.asked.allSatisfy { $0.tags && $0.mode == nil })
        #expect(try await embedRows(database).values.allSatisfy { $0.version == nil })

        let embedders = FakeEmbedders()
        let embedding = queue(database, indexer, analyzer, embedders: embedders, vectors: vectors)
        await embedding.run()
        let second = analyzer.asked.dropFirst(3)
        #expect(Set(second.map(\.localID)) == ["a", "b", "c"])
        #expect(second.allSatisfy { !$0.tags && $0.mode == .foreground }, "only the vectors were due")
        #expect(try await embedRows(database).values.allSatisfy { $0.version == EmbedPass.version && $0.units == EmbedUnits.all.rawValue })
        #expect(try await IndexReader(database: database).visualStats().labelRows == 3, "the tags stay")
        let store = try #require(await vectors.current)
        #expect(await store.count == 3)
        let a = try #require(try await idByLocalID(database)["a"])
        let vector = try #require(try await store.vector(for: a))
        #expect(vector[Int(a % 8)] > 0.99)
        #expect(embedders.loads == [.foreground] && embedders.releases == 1, "loaded once, let go at the end")

        // Nothing is due again.
        await embedding.run()
        #expect(analyzer.asked.count == 6)
        #expect(embedders.loads.count == 1, "no photo needed the model")
    }

    @Test func tagsAndAVectorComeFromOneLook() async throws {
        let (database, indexer, vectors) = try await index(FakeLibraryReader(.explicit([Fixture.photo("a", Self.now)])))
        let analyzer = Analyzer()
        await queue(database, indexer, analyzer, embedders: FakeEmbedders(), vectors: vectors).run()
        #expect(analyzer.asked == [Analyzer.Ask(localID: "a", tags: true, mode: .foreground)])
        #expect(try await embedRows(database)["a"]?.version == EmbedPass.version)
    }

    @Test func withoutAModelThereAreNoVectors() async throws {
        let (database, indexer, vectors) = try await index(FakeLibraryReader(.explicit([Fixture.photo("a", Self.now)])))
        let analyzer = Analyzer()
        let embedders = FakeEmbedders(model: nil)
        let queue = queue(database, indexer, analyzer, embedders: embedders, vectors: vectors)
        let stream = queue.progress
        await queue.run()
        #expect(analyzer.asked == [Analyzer.Ask(localID: "a", tags: true, mode: nil)])
        #expect(embedders.loads.isEmpty && embedders.releases == 0)
        #expect(await vectors.current == nil)
        for await progress in stream where progress.state == .done {
            #expect(progress.embedded == nil, "no model, no vector count")
            break
        }
    }

    // MARK: Order

    @Test func theReferenceSampleGoesFirst() async throws {
        let photos = (0..<10).map { Fixture.photo(String(format: "p%02d", $0), Self.now - Int64($0) * 3_600) }
        let (database, indexer, vectors) = try await index(FakeLibraryReader(.explicit(photos)))
        let analyzer = Analyzer()
        await queue(database, indexer, analyzer, embedders: FakeEmbedders(), vectors: vectors, referenceSize: 3).run()
        let ids = try await idByLocalID(database)
        let reference = ReferenceSample.pick(ids.values, count: 3)
        let asked = analyzer.asked.map(\.localID)
        #expect(Set(asked.prefix(3).map { ids[$0]! }) == reference)
        let rest = asked.dropFirst(3)
        #expect(Array(rest) == rest.sorted(), "then newest first")
    }

    @Test func theReferenceSampleIsAStableRandomThousand() {
        let ids = (1...5_000).map(Int64.init)
        let picked = ReferenceSample.pick(ids)
        #expect(picked.count == ReferenceSample.size)
        #expect(ReferenceSample.pick(ids.reversed()) == picked, "a function of the ids, not their order")
        #expect(picked.filter { $0 <= 2_500 }.count > 400 && picked.filter { $0 <= 2_500 }.count < 600, "spread over the library")
        #expect(ReferenceSample.pick(ids + [5_001]).symmetricDifference(picked).count <= 2, "a new photo moves at most one")
        #expect(ReferenceSample.pick([Int64(1), 2]) == [1, 2])
    }

    // MARK: Keeping vectors right

    @Test func anEditedPhotoIsEmbeddedAgain() async throws {
        let reader = FakeLibraryReader(.explicit([Fixture.photo("a", Self.now), Fixture.photo("b", Self.now - 60)]))
        let (database, indexer, vectors) = try await index(reader)
        let analyzer = Analyzer()
        let queue = queue(database, indexer, analyzer, embedders: FakeEmbedders(), vectors: vectors)
        await queue.run()
        var edited = Fixture.photo("a", Self.now)
        edited.adjustedDate = Fixture.now
        edited.hasAdjustments = true
        reader.update([edited])
        await Fixture.sync(indexer, .sync(.libraryChanged))
        await queue.run()
        #expect(analyzer.asked.map(\.localID) == ["a", "b", "a"])
        #expect(analyzer.asked.last == Analyzer.Ask(localID: "a", tags: true, mode: .foreground), "tags and vector again")
        #expect(try await embedRows(database)["a"]?.version == EmbedPass.version)
    }

    @Test func aDeletedPhotoLosesItsVector() async throws {
        let reader = FakeLibraryReader(.explicit([Fixture.photo("a", Self.now), Fixture.photo("b", Self.now - 60)]))
        let (database, indexer, vectors) = try await index(reader)
        let queue = queue(database, indexer, Analyzer(), embedders: FakeEmbedders(), vectors: vectors)
        await queue.run()
        let gone = try #require(try await idByLocalID(database)["a"])
        reader.delete(["a"])
        await Fixture.sync(indexer, .sync(.libraryChanged))
        await queue.run()
        let store = try #require(await vectors.current)
        #expect(await store.count == 1)
        #expect(!(await store.contains(gone)))
    }

    @Test func anotherModelEmbedsEveryPhotoAgain() async throws {
        let (database, indexer, vectors) = try await index(FakeLibraryReader(.explicit([Fixture.photo("a", Self.now), Fixture.photo("b", Self.now - 60)])))
        let analyzer = Analyzer()
        await queue(database, indexer, analyzer, embedders: FakeEmbedders(), vectors: vectors).run()
        await queue(database, indexer, analyzer, embedders: FakeEmbedders(model: Self.model(id: "fake-other")), vectors: vectors).run()
        #expect(analyzer.asked.map(\.localID) == ["a", "b", "a", "b"])
        #expect(analyzer.asked.suffix(2).allSatisfy { !$0.tags }, "the tags stay")
        let store = try #require(await vectors.current)
        // An in-memory index's file is a fresh temporary one per store; on disk the old model's file is discarded.
        #expect(store.modelID == "fake-other")
        #expect(await store.count == 2)
    }

    @Test func vectorsMadeOnTheCPUAreMadeAgainInTheForeground() async throws {
        let (database, indexer, vectors) = try await index(FakeLibraryReader(.explicit([Fixture.photo("a", Self.now), Fixture.photo("b", Self.now - 60)])))
        let analyzer = Analyzer()
        let embedders = FakeEmbedders()
        let queue = queue(database, indexer, analyzer, embedders: embedders, vectors: vectors)
        await queue.setMode(.background)
        await queue.run()
        #expect(analyzer.asked.allSatisfy { $0.mode == .background })
        #expect(try await embedRows(database).values.allSatisfy { $0.units == EmbedUnits.cpu.rawValue })
        // Still in the background: nothing due.
        await queue.run()
        #expect(analyzer.asked.count == 2)
        await queue.setMode(.foreground)
        await queue.run()
        #expect(analyzer.asked.suffix(2).allSatisfy { !$0.tags && $0.mode == .foreground })
        #expect(try await embedRows(database).values.allSatisfy { $0.units == EmbedUnits.all.rawValue })
        #expect(embedders.loads == [.background, .foreground])
    }

    @Test func aVectorTheModelCouldntMakeWaitsForTheRetry() async throws {
        let clock = FixedClock(Fixture.now)
        let (database, indexer, vectors) = try await index(FakeLibraryReader(.explicit([Fixture.photo("a", Self.now), Fixture.photo("b", Self.now - 60),
                                                                                       Fixture.photo("c", Self.now - 120)])))
        let analyzer = Analyzer(noVector: ["a", "b"])
        // Tags first, then the model: "a" fails on a vector-only try, "b" on a try with its tags.
        await queue(database, indexer, Analyzer(), embedders: nil, vectors: vectors).run()
        try await database.write { db in try db.execute(sql: "UPDATE asset_visual SET labels_version = 0 WHERE asset_id = (SELECT id FROM asset WHERE local_id = 'b')") }
        let queue = queue(database, indexer, analyzer, embedders: FakeEmbedders(), vectors: vectors, clock: clock)
        let stream = queue.progress
        await queue.run()
        let rows = try await embedRows(database)
        #expect(rows["a"]?.units == EmbedUnits.failed.rawValue && rows["b"]?.units == EmbedUnits.failed.rawValue)
        #expect(rows["c"]?.units == EmbedUnits.all.rawValue)
        for await progress in stream where progress.state == .done {
            #expect(progress.embedded == 1, "a failed try isn't a vector")
            break
        }
        let asked = analyzer.asked.count
        await queue.run()
        #expect(analyzer.asked.count == asked, "not tried again at once")
        await clock.advance(by: .seconds(Int(VisualPolicy.default.cloudRetry) + 1))
        await queue.run()
        #expect(Set(analyzer.asked.dropFirst(asked).map(\.localID)) == ["a", "b"])
    }

    @Test func twoRunsAtOnceKeepTheirOwnModel() async throws {
        let (database, indexer, vectors) = try await index(FakeLibraryReader(.explicit(Fixture.library(12))))
        let embedders = FakeEmbedders()
        let queue = queue(database, indexer, Analyzer(), embedders: embedders, vectors: vectors)
        // A run cancelled by the scene going away can still be finishing when the next one starts.
        let first = Task { await queue.run() }
        let second = Task { await queue.run() }
        await first.value
        await second.value
        await queue.run()
        #expect(try await embedRows(database).values.allSatisfy { $0.version == EmbedPass.version && $0.units == EmbedUnits.all.rawValue })
        let store = try #require(await vectors.current)
        #expect(await store.count == 12)
    }

    // MARK: Progress

    @Test func progressCountsVectors() async throws {
        let (database, indexer, vectors) = try await index(FakeLibraryReader(.explicit(Fixture.library(6))))
        let queue = queue(database, indexer, Analyzer(), embedders: FakeEmbedders(), vectors: vectors)
        let stream = queue.progress
        await queue.run()
        var last: VisualProgress?
        for await progress in stream {
            last = progress
            if progress.state == .done { break }
        }
        #expect(last?.embedded == 6 && last?.checked == 6)
        #expect(last?.vectorsPerSecond != nil && last?.modelLoad == .milliseconds(5))
        #expect(last?.peakFootprint != nil)
    }
}
