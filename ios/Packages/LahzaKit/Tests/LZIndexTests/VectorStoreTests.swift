import Foundation
import GRDB
import LZLibrary
import Testing
@testable import LZIndex

struct VectorStoreTests {
    static let model = "test-model"

    /// A unit vector along `axis`, leaning towards `lean` by `amount`.
    private func vector(_ axis: Int, lean: Int? = nil, amount: Float = 0, dimension: Int = 8) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        vector[axis] = 1
        if let lean { vector[lean] = amount }
        return VectorStore.normalized(vector)
    }

    private func open(_ database: IndexDatabase, model: String = model, dimension: Int = 8) async throws -> VectorStore {
        try await VectorStore.open(database, modelID: model, dimension: dimension)
    }

    @Test func vectorsSurviveReopeningWithinSixteenBitPrecision() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            let store = try await open(database)
            #expect(store.opening == .created)
            let leaning = vector(0, lean: 3, amount: 0.37)
            try await store.upsert([VectorEntry(assetID: 7, vector: leaning), VectorEntry(assetID: 9, vector: vector(1))])

            let reopened = try await open(database)
            #expect(reopened.opening == .existing)
            #expect(await reopened.count == 2)
            let read = try #require(try await reopened.vector(for: 7))
            #expect(zip(read, leaning).allSatisfy { abs($0 - $1) < 0.001 })
            #expect(try await reopened.vector(for: 8) == nil)
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("Index/\(VectorStore.fileName)").path),
                    "next to the database, so Delete index removes it")
            await database.close()
        }
    }

    @Test func anUpsertReplacesAndARemovedRowIsReused() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let store = try await open(database)
        try await store.upsert((1...3).map { VectorEntry(assetID: Int64($0), vector: vector($0)) })
        let size = try fileSize(store)

        try await store.upsert([VectorEntry(assetID: 2, vector: vector(5))])
        #expect(await store.count == 3)
        #expect(try await store.vector(for: 2).map { $0[5] > 0.99 } == true, "replaced in place")
        #expect(try fileSize(store) == size)

        try await store.remove([2, 42])
        #expect(await store.count == 2)
        #expect(try await store.scores(for: vector(5)).assetIDs == [1, 3], "a removed asset is never scored")
        try await store.upsert([VectorEntry(assetID: 4, vector: vector(6))])
        #expect(try fileSize(store) == size, "the free row is reused")
        #expect(try await store.scores(for: vector(6)).top(1).first?.assetID == 4)
    }

    @Test func scoresAreCosinesAndTopOrdersThem() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let store = try await open(database)
        try await store.upsert([
            VectorEntry(assetID: 1, vector: vector(0)),
            VectorEntry(assetID: 2, vector: vector(1)),
            VectorEntry(assetID: 3, vector: vector(0, lean: 1, amount: 1)),
            VectorEntry(assetID: 4, vector: [2, 0, 0, 0, 0, 0, 0, 0]),
        ])
        let scores = try await store.scores(for: [5, 0, 0, 0, 0, 0, 0, 0])
        #expect(scores.assetIDs == [1, 2, 3, 4], "file order")
        #expect(zip(scores.scores, [1, 0, 0.7071, 1]).allSatisfy { abs($0 - $1) < 0.001 }, "stored and queried as unit vectors")
        #expect(scores.top(3).map(\.assetID) == [1, 4, 3], "best first, ties by asset id")
    }

    @Test func manyRowsScoreAcrossBlocks() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let store = try await open(database, dimension: 16)
        let count = VectorStore.block * 2 + 37
        try await store.upsert((1...count).map { VectorEntry(assetID: Int64($0), vector: vector($0 % 16, dimension: 16)) })
        let scores = try await store.scores(for: vector(3, dimension: 16))
        #expect(scores.assetIDs.count == count)
        #expect(scores.assetIDs.indices.allSatisfy { (scores.scores[$0] > 0.99) == (scores.assetIDs[$0] % 16 == 3) })
    }

    @Test func anotherModelOrDimensionStartsAgain() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            try await open(database).upsert([VectorEntry(assetID: 1, vector: vector(0))])

            let other = try await open(database, model: "other-model")
            #expect(other.opening == .discarded(reason: "model"))
            #expect(await other.count == 0)
            try await other.upsert([VectorEntry(assetID: 1, vector: vector(0, dimension: 8))])
            let wider = try await open(database, model: "other-model", dimension: 16)
            #expect(wider.opening == .discarded(reason: "dimension"))
            await database.close()
        }
    }

    @Test func aDamagedOrForeignFileStartsAgainAndACutRowIsDropped() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            let store = try await open(database)
            try await store.upsert([VectorEntry(assetID: 1, vector: vector(0)), VectorEntry(assetID: 2, vector: vector(1))])
            let file = url.appendingPathComponent("Index/\(VectorStore.fileName)")
            // A write cut short leaves part of a row.
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([1, 2, 3]))
            try handle.close()
            let reopened = try await open(database)
            #expect(reopened.opening == .existing)
            #expect(await reopened.count == 2)
            #expect(try fileSize(reopened) == VectorStore.headerSize + 2 * (8 + 8 * 2))

            try Data("not vectors".utf8).write(to: file)
            #expect(try await open(database).opening == .discarded(reason: "no header"))
            await database.close()
        }
    }

    @Test func aRetiredStoreKeepsReadingItsOwnFile() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            let old = try await open(database)
            try await old.upsert((1...3).map { VectorEntry(assetID: Int64($0), vector: vector($0)) })
            // A model switch replaces the file while the old store is still held.
            let new = try await open(database, model: "other-model")
            #expect(new.opening == .discarded(reason: "model"))
            #expect(try await old.scores(for: vector(2)).top(1).first?.assetID == 2, "its own file, not the new empty one")
            #expect(await new.count == 0)
            await database.close()
        }
    }

    @Test func aFileThatCantBeReadNowIsKeptForLater() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            try await open(database).upsert([VectorEntry(assetID: 1, vector: vector(0))])
            let file = url.appendingPathComponent("Index/\(VectorStore.fileName)").path
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
            await #expect(throws: (any Error).self) { try await open(database) }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
            let later = try await open(database)
            #expect(later.opening == .existing, "never discarded for a read error")
            #expect(await later.count == 1)
            await database.close()
        }
    }

    @Test func settingsRebuildRetiresTheVectors() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, FakeLibraryReader(.explicit(Fixture.library(5))))
        await Fixture.sync(indexer)
        let store = try await open(database)
        try await store.upsert([VectorEntry(assetID: 1, vector: vector(0))])
        #expect(try await store.isCurrent())

        await indexer.enqueue(.rebuild)
        await indexer.settled()
        #expect(try await store.isCurrent() == false, "every asset has a new id")
        #expect(try await Fixture.count(database, "asset") == 5)
    }

    @Test func aRebuildAtOpenRetiresTheVectors() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            try await open(database).upsert([VectorEntry(assetID: 1, vector: vector(0))])
            await database.close()
            let queue = try DatabaseQueue(path: url.appendingPathComponent("Index/index.sqlite").path)
            try await queue.write { db in try db.execute(sql: "PRAGMA user_version = 999") }
            try queue.close()

            let rebuilt = try IndexDatabase.open(.directory(url))
            let store = try await open(rebuilt)
            #expect(store.opening == .discarded(reason: "index rebuilt"), "asset ids restart with the new file")
            #expect(await store.count == 0)
            await rebuilt.close()
        }
    }

    @Test func anInMemoryIndexKeepsItsVectorsInATemporaryFile() async throws {
        var url: URL?
        do {
            let store = try await open(try IndexDatabase.open(.inMemory))
            try await store.upsert([VectorEntry(assetID: 1, vector: vector(0))])
            url = store.url
            #expect(FileManager.default.fileExists(atPath: store.url.path))
        }
        #expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == false, "removed with the store")
    }

    private func fileSize(_ store: VectorStore) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: store.url.path)[.size] as? Int ?? -1
    }
}
