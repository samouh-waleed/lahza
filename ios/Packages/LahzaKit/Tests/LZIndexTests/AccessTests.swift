import Foundation
import LZLibrary
import Testing
@testable import LZIndex

/// Photo access and the library's availability: limited access always reads the selection again, a scope
/// change rescans, no access turns the indexer off, a revocation mid-scan purges behind the close fence, and an
/// unavailable library pauses until the next sync rescans.
@Suite struct AccessTests {
    @Test func limitedAccessReadsTheSelectionAgainOnEverySync() async throws {
        let reader = FakeLibraryReader(.explicit(Fixture.library(20)))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader)
        await Fixture.sync(indexer)

        reader.setLimitedSelection(["a00001", "a00002", "a00003", "a00004", "a00005"])
        reader.setAccess(.limited)
        await Fixture.sync(indexer, .sync(.accessChanged))
        #expect(await indexer.stats.fullScans[.accessScopeChanged] == 1)
        #expect(try await Fixture.localIDs(database) == ["a00001", "a00002", "a00003", "a00004", "a00005"], "the sweep removed the rest")

        reader.setLimitedSelection(["a00001", "a00002", "a00003", "a00004", "a00005", "a00010", "a00011"])
        await Fixture.sync(indexer, .sync(.foreground))
        #expect(await indexer.stats.fullScans[.limitedAccess] == 1, "a selection change shows up only in a full diff")
        #expect(try await Fixture.localIDs(database).count == 7)
        #expect(await indexer.stats.deltas == 0)

        var iterator = indexer.status.makeAsyncIterator()
        #expect(await iterator.next()?.isLimited == true)

        reader.setAccess(.full)
        await Fixture.sync(indexer, .sync(.accessChanged))
        #expect(await indexer.stats.fullScans[.accessScopeChanged] == 2)
        #expect(try await Fixture.localIDs(database).count == 20)
    }

    @Test func withoutAccessTheIndexerIsOff() async throws {
        let reader = FakeLibraryReader(.explicit(Fixture.library(5)), access: .denied)
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader)
        await Fixture.sync(indexer)
        var iterator = indexer.status.makeAsyncIterator()
        #expect(await iterator.next()?.phase == .off(.noAccess))
        #expect(try await Fixture.count(database, "asset") == 0)
        #expect(try await Fixture.count(database, "meta") == 0)
    }

    @Test func revokingAccessMidScanPurgesTheIndex() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let location = IndexLocation.directory(url)
            let reader = FakeLibraryReader(.seed(.hero))
            let database = try IndexDatabase.open(location)
            let (reached, signal) = AsyncStream<Void>.makeStream()
            let indexer = Fixture.indexer(database, reader, settings: IndexerSettings(batchSize: 50, pacePerBatch: .milliseconds(20)),
                                          faults: IndexFaults { if $0 == .scanBatch(1) { signal.yield() } })
            await indexer.enqueue(.sync(.launch))
            var iterator = reached.makeAsyncIterator()
            await iterator.next()

            // The purge order IndexStore follows on revocation.
            reader.setAccess(.denied)
            await indexer.stop()
            await database.close()
            try IndexDatabase.destroy(location)

            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("Index").path))
            #expect(await indexer.stats.writes.inserted < 561, "stopped mid-scan")
            await #expect(throws: IndexError.closed) { try await IndexReader(database: database).summary() }
            await #expect(throws: IndexError.closed) { try await IndexReader(database: database).inspector() }
        }
    }

    @Test func anUnavailableLibraryPausesUntilTheNextSyncRescans() async throws {
        let reader = FakeLibraryReader(.explicit(Fixture.library(10)))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader)
        await Fixture.sync(indexer)
        let recorder = StatusRecorder(indexer.status)

        reader.makeUnavailable()
        try await waitUntil { recorder.values.last?.phase == .failed(LibraryIndexer.unavailableMessage) }
        await Fixture.sync(indexer, .sync(.libraryChanged))
        #expect(await indexer.stats.fullScans == [.firstRun: 1], "paused: nothing runs")

        // The next return to the foreground resumes and syncs.
        await indexer.resume()
        await Fixture.sync(indexer, .sync(.foreground))
        #expect(await indexer.stats.fullScans[.libraryUnavailable] == 1)
        try await waitUntil { recorder.values.last?.phase == .ready }
        recorder.cancel()
    }
}
