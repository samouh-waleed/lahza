import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Synchronization
import Testing
@testable import LZIndex

/// Incremental sync (P5): deltas from the change history, the token written only with the last chunk, the
/// empty-delta retry, the large-delta rescan, the full-scan fallbacks and derivation-version changes.
@Suite struct IncrementalSyncTests {
    /// An indexed library and the means to change it.
    private struct Indexed {
        let reader: FakeLibraryReader
        let database: IndexDatabase
        let indexer: LibraryIndexer
    }

    private func indexed(_ assets: [LibraryAsset] = Fixture.library(12), settings: IndexerSettings = .init(),
                         faults: IndexFaults? = nil, clock: any AppClock = FixedClock(Fixture.now)) async throws -> Indexed {
        let reader = FakeLibraryReader(.explicit(assets))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader, settings: settings, faults: faults, clock: clock)
        await Fixture.sync(indexer)
        return Indexed(reader: reader, database: database, indexer: indexer)
    }

    private func day(_ database: IndexDatabase, _ id: String) async throws -> Int32? {
        try await database.read { db in try Int32.fetchOne(db, sql: "SELECT day FROM asset WHERE local_id = ?", arguments: [id]) }
    }

    private func clearDirtyDays(_ database: IndexDatabase) async throws {
        try await database.write { db in try db.execute(sql: "DELETE FROM dirty_day") }
    }

    // MARK: Deltas

    @Test func insertsUpdatesAndDeletesArriveAsDeltas() async throws {
        let index = try await indexed()
        try await clearDirtyDays(index.database)

        index.reader.insert([Fixture.photo("new", 1_736_000_000, at: Fixture.athens)])
        await Fixture.sync(index.indexer, .sync(.libraryChanged))
        #expect(try await Fixture.localIDs(index.database).contains("new"))
        #expect(await index.indexer.stats.deltas == 1)
        #expect(await index.indexer.stats.fullScans == [.firstRun: 1])
        #expect(try await Fixture.dirtyDays(index.database) == [try #require(await day(index.database, "new"))])

        // 2025-01-01 21:00 UTC: 00:00 on 2 Jan in Riyadh (still 1 Jan's moment day), 08:00 on 2 Jan in Sydney.
        try await clearDirtyDays(index.database)
        var moved = Fixture.photo("moving", 1_735_765_200, at: Fixture.nakheel)
        index.reader.insert([moved])
        await Fixture.sync(index.indexer, .sync(.libraryChanged))
        let before = try #require(await day(index.database, "moving"))
        #expect(before == LocalTime.day(year: 2025, month: 1, day: 1))
        try await clearDirtyDays(index.database)
        moved.facts.coordinate = Fixture.sydney
        index.reader.update([moved])
        await Fixture.sync(index.indexer, .sync(.libraryChanged))
        let after = try #require(await day(index.database, "moving"))
        #expect(after == LocalTime.day(year: 2025, month: 1, day: 2))
        #expect(try await Fixture.dirtyDays(index.database) == [before, after], "a moved photo dirties its old and new day")

        try await clearDirtyDays(index.database)
        index.reader.delete(["moving"])
        await Fixture.sync(index.indexer, .sync(.libraryChanged))
        #expect(try await !Fixture.localIDs(index.database).contains("moving"))
        #expect(try await Fixture.dirtyDays(index.database) == [after])
        #expect(try await Fixture.assetRows(index.database) == Fixture.assetRows(Fixture.cleanBuild(of: index.reader)))
    }

    @Test func hidingDeletesAndUnhidingInsertsAgain() async throws {
        let index = try await indexed()
        index.reader.hide(["a00003", "a00004"])
        await Fixture.sync(index.indexer)
        #expect(try await Fixture.localIDs(index.database).count == 10)
        index.reader.unhide(["a00003"])
        await Fixture.sync(index.indexer)
        let ids = try await Fixture.localIDs(index.database)
        #expect(ids.contains("a00003"))
        #expect(!ids.contains("a00004"))
        #expect(await index.indexer.stats.deltas == 2)
    }

    @Test func reReadsWithUnchangedFactsWriteNothing() async throws {
        let assets = Fixture.library(12)
        let index = try await indexed(assets)
        let before = await index.indexer.stats.writes
        index.reader.update(Array(assets.prefix(5)))
        await Fixture.sync(index.indexer)
        let delta = await index.indexer.stats.writes - before
        #expect(delta == WriteCounts(unchanged: 5))

        // A modification date alone is not an indexed fact.
        var touched = assets[6]
        touched.facts.modificationDate = Fixture.now
        index.reader.update([touched])
        await Fixture.sync(index.indexer)
        #expect((await index.indexer.stats.writes - before).updated == 0)

        // A full rescan stamps every row's generation without rewriting its facts.
        index.reader.expireTokens()
        let beforeScan = await index.indexer.stats.writes
        await Fixture.sync(index.indexer)
        #expect(await index.indexer.stats.writes - beforeScan == WriteCounts(unchanged: 12))
    }

    @Test func theTokenAdvancesOnlyWithTheLastChunk() async throws {
        let failing = Mutex(true)
        let faults = IndexFaults { point in
            if case .deltaChunk(index: 2, isLast: true) = point, failing.withLock({ $0 }) { throw Kill() }
        }
        let index = try await indexed(Fixture.library(6), settings: IndexerSettings(batchSize: 2), faults: faults)
        let oldToken = try await Fixture.meta(index.database).libraryToken
        index.reader.insert((0..<5).map { Fixture.photo("new\($0)", 1_740_000_000 + Int64($0) * 60, at: Fixture.nakheel) })

        await Fixture.sync(index.indexer)
        #expect(try await Fixture.meta(index.database).libraryToken == oldToken, "the last chunk rolled back with the token")
        #expect(try await Fixture.localIDs(index.database).filter { $0.hasPrefix("new") } == ["new0", "new1", "new2", "new3"],
                "the first two chunks committed")

        failing.withLock { $0 = false }
        await Fixture.sync(index.indexer)
        let newToken = try index.reader.currentToken()
        #expect(try await Fixture.meta(index.database).libraryToken == newToken)
        #expect(try await Fixture.assetRows(index.database) == Fixture.assetRows(Fixture.cleanBuild(of: index.reader)), "the replay converged")
    }

    @Test func anEmptyDeltaAfterAChangeEventIsAskedAgainOnce() async throws {
        let clock = FixedClock(Fixture.now)
        let index = try await indexed(clock: clock)
        await index.indexer.enqueue(.sync(.libraryChanged))
        #expect(await clock.waitForSleepers(1), "history lagging the observer: the sync waits to ask again")
        index.reader.insert([Fixture.photo("late", 1_745_000_000)])
        await clock.advance(by: .seconds(2))
        await index.indexer.settled()
        #expect(try await Fixture.localIDs(index.database).contains("late"))

        // Other triggers don't wait.
        await Fixture.sync(index.indexer, .sync(.foreground))
        #expect(clock.pendingSleepCount == 0)
    }

    @Test func aLargeDeltaIsAppliedAsAFullScan() async throws {
        let index = try await indexed(Fixture.library(10), settings: IndexerSettings(reconcileThreshold: (3, 0.2)))
        index.reader.insert((0..<4).map { Fixture.photo("bulk\($0)", 1_750_000_000 + Int64($0)) })
        await Fixture.sync(index.indexer)
        #expect(await index.indexer.stats.fullScans[.tooManyChanges] == 1)
        #expect(await index.indexer.stats.deltas == 0)

        // 3 changes is not more than max(3, 20% of 14).
        index.reader.insert((0..<3).map { Fixture.photo("small\($0)", 1_760_000_000 + Int64($0)) })
        await Fixture.sync(index.indexer)
        #expect(await index.indexer.stats.deltas == 1)
        #expect(try await Fixture.count(index.database, "asset") == 17)
    }

    // MARK: Full-scan fallbacks

    @Test func historyThatCantAnswerFallsBackToAFullScan() async throws {
        let index = try await indexed()
        index.reader.insert([Fixture.photo("one", 1_736_100_000)])
        index.reader.expireTokens()
        await Fixture.sync(index.indexer)

        index.reader.delete(["one"])
        index.reader.setDetailsUnavailable(true)
        await Fixture.sync(index.indexer)
        index.reader.setDetailsUnavailable(false)

        try await index.database.write { db in try Meta.set(db, .libraryToken, Data("not a token".utf8)) }
        await Fixture.sync(index.indexer)

        try await index.indexer.forgetChangeToken()
        await Fixture.sync(index.indexer)

        #expect(await index.indexer.stats.fullScans == [.firstRun: 1, .tokenExpired: 2, .detailsUnavailable: 1, .undecodableToken: 1])
        #expect(try await Fixture.assetRows(index.database) == Fixture.assetRows(Fixture.cleanBuild(of: index.reader)))
    }

    // MARK: Derivation versions

    @Test func aNewDeviceZoneDerivesTheGPSlessAssetsAgain() async throws {
        let zone = Mutex(Fixture.riyadh)
        let reader = FakeLibraryReader(.explicit([
            Fixture.photo("gpsless", 1_735_781_400),                       // 2025-01-02 01:30 UTC
            Fixture.photo("located", 1_735_781_400, at: Fixture.nakheel),
        ]))
        let database = try IndexDatabase.open(.inMemory)
        await Fixture.sync(Fixture.indexer(database, reader, zone: { zone.withLock { $0 } }))
        #expect(try await day(database, "gpsless") == LocalTime.day(year: 2025, month: 1, day: 2), "04:30 in Riyadh")
        try await clearDirtyDays(database)

        zone.withLock { $0 = TimeZone(identifier: "Europe/London")! }
        let indexer = Fixture.indexer(database, reader, zone: { zone.withLock { $0 } })
        await Fixture.sync(indexer)
        #expect(try await day(database, "gpsless") == LocalTime.day(year: 2025, month: 1, day: 1), "01:30 in London, before the 04:00 break")
        #expect(try await day(database, "located") == LocalTime.day(year: 2025, month: 1, day: 2), "GPS keeps its own zone")
        #expect(try await Fixture.dirtyDays(database) == [LocalTime.day(year: 2025, month: 1, day: 1), LocalTime.day(year: 2025, month: 1, day: 2)])
        #expect(try await database.read { db in try Meta.string(db, .deviceTimeZone) } == "Europe/London")
    }

    @Test func aNewStructureVersionDirtiesEveryDay() async throws {
        let index = try await indexed()
        try await clearDirtyDays(index.database)
        try await index.database.write { db in try Meta.set(db, .structureVersion, 0) }
        let structure = RecordingStructurePass()
        await Fixture.sync(Fixture.indexer(index.database, index.reader, structure: structure), .restructure)
        let days = try await index.database.read { db in Set(try Int32.fetchAll(db, sql: "SELECT DISTINCT day FROM asset")) }
        #expect(try await Fixture.dirtyDays(index.database) == days)
        #expect(structure.calls == [.init(daysAfter: nil, final: true)])
        #expect(try await Fixture.meta(index.database).version == 2)
    }

    @Test func aNewGazetteerDerivesTheLocatedAssetsAgain() async throws {
        let index = try await indexed([Fixture.photo("athens", 1_720_000_000, at: Fixture.athens)])
        let expected = try await Fixture.assetRows(index.database)
        try await index.database.write { db in
            try Meta.set(db, .gazetteerVersion, 1)
            try db.execute(sql: "INSERT INTO zone (name) VALUES ('Pacific/Kiritimati')")
            try db.execute(sql: "UPDATE asset SET tz = (SELECT id FROM zone WHERE name = 'Pacific/Kiritimati'), day = 0, wall_s = 0")
        }
        await Fixture.sync(Fixture.indexer(index.database, index.reader), .restructure)
        #expect(try await Fixture.assetRows(index.database) == expected)
        #expect(try await index.database.read { db in try Meta.int(db, .rederiveLocated) } == nil)
    }
}
