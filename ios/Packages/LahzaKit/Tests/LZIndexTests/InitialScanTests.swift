import Foundation
import GRDB
import LZGeo
import LZLibrary
import Synchronization
import Testing
@testable import LZIndex

/// The first build (P0): the seed library, batches and progress, resuming after an interruption, the catch-up
/// delta, undated assets, the sweep, progressive checkpoints, and the job queue.
@Suite struct InitialScanTests {
    // MARK: The seed library

    @Test func theHeroSeedIsIndexedWithZonesAndDays() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, FakeLibraryReader(.seed(.hero)))
        await Fixture.sync(indexer)

        let scenario = SeedScenario.hero
        let summary = try await IndexReader(database: database).summary()
        #expect(summary.assets == 561)
        #expect(summary.videos == scenario.expectedVideoCount)
        #expect(summary.photos == 561 - scenario.expectedVideoCount)
        #expect(summary.located == scenario.expectedLocatedCount)
        #expect(summary.firstYear == 2021)
        #expect(summary.lastYear == 2026)

        struct Derived: Sendable {
            var zone: String?
            var source: Int
            var day: Int32?
            var cell: String?
            var created: Int64?
        }
        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT a.local_id, z.name AS zone, a.tz_src, a.day, a.cell, a.created_utc FROM asset a LEFT JOIN zone z ON z.id = a.tz")
                .map { row in (row["local_id"] as String, Derived(zone: row["zone"], source: row["tz_src"], day: row["day"], cell: row["cell"], created: row["created_utc"])) }
        }
        let byID = Dictionary(uniqueKeysWithValues: rows)
        for item in scenario.items {
            let row = try #require(byID[item.id])
            if let coordinate = item.coordinate {
                // Located: the zone of the nearest gazetteer place, so the local day matches the scenario's.
                #expect(row.zone == item.zone, "\(item.id) \(item.title)")
                #expect(row.day == item.momentDay, "\(item.id) \(item.title)")
                #expect(row.cell == GeoHash.encode(coordinate, precision: 7))
                #expect(row.source == ZoneSource.gps.rawValue)
            } else if item.utc != nil {
                #expect(row.zone == "Asia/Riyadh", "GPS-less: the device zone until the structure pass borrows one")
                #expect(row.source == ZoneSource.device.rawValue)
            } else {
                #expect(row.created == nil)
                #expect(row.day == nil, "undated: no day")
            }
        }

        let state = try await Fixture.meta(database)
        #expect(state.phase == .idle)
        #expect(state.firstBuildDone)
        #expect(state.libraryToken != nil)
        #expect(state.pendingToken == nil)
        #expect(state.version >= 1)
        #expect(await indexer.stats.fullScans == [.firstRun: 1])
    }

    @Test func aPartyPastMidnightStaysOnItsEvening() async throws {
        // London, Fri 31 Dec 2021 22:00 → Sat 1 Jan 02:30: one moment day (31 Dec).
        let database = try IndexDatabase.open(.inMemory)
        await Fixture.sync(Fixture.indexer(database, FakeLibraryReader(.seed(.hero))))
        let party = SeedScenario.hero.items(.london).filter { item in
            guard let wall = item.wallSeconds, let civilDay = item.civilDay else { return false }
            return civilDay == LocalTime.day(year: 2022, month: 1, day: 1) && LocalTime.minuteOfDay(wallSeconds: wall) < 4 * 60
        }
        #expect(!party.isEmpty)
        let days = try await database.read { db in
            try Int32.fetchAll(db, sql: "SELECT day FROM asset WHERE local_id IN (\(party.map { "'\($0.id)'" }.joined(separator: ",")))")
        }
        #expect(Set(days) == [LocalTime.day(year: 2021, month: 12, day: 31)])
    }

    // MARK: Batches

    @Test func batchesReportProgressNewestFirst() async throws {
        let assets = Fixture.library(23) + [Fixture.photo("undated-1", nil), Fixture.photo("undated-2", nil, at: Fixture.athens)]
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, FakeLibraryReader(.explicit(assets)), settings: IndexerSettings(batchSize: 5, progressInterval: .zero))
        let recorder = StatusRecorder(indexer.status)
        await Fixture.sync(indexer)
        try await Task.sleep(for: .milliseconds(50))
        recorder.cancel()

        var reading: [(done: Int, total: Int, covered: Date?)] = []
        for status in recorder.values {
            if case .reading(let done, let total) = status.phase { reading.append((done, total, status.coveredSince)) }
        }
        #expect(!reading.isEmpty)
        #expect(reading.allSatisfy { $0.total == 25 })
        #expect(zip(reading, reading.dropFirst()).allSatisfy { $0.done <= $1.done })
        let covered = reading.compactMap(\.covered)
        #expect(zip(covered, covered.dropFirst()).allSatisfy { $0 >= $1 }, "the frontier only moves back in time")
        let last = try #require(recorder.values.last)
        #expect(last.phase == .ready)
        #expect(!last.isPartial)
        #expect(last.coveredSince == nil)
        #expect(last.summary?.assets == 25)
        #expect(await indexer.stats.writes.inserted == 25)

        // The undated located photo has a zone from its GPS, but no wall time or day.
        let undated = try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT z.name AS zone, a.day FROM asset a JOIN zone z ON z.id = a.tz WHERE local_id = 'undated-2'")
                .map { ($0["zone"] as String, $0["day"] as Int32?) }
        }
        #expect(undated?.0 == "Europe/Athens")
        #expect(undated?.1 == nil)
    }

    @Test func otherMediaIsNotIndexed() async throws {
        let assets = Fixture.library(3) + [Fixture.photo("audio", 1_735_000_000, kind: .other)]
        let database = try IndexDatabase.open(.inMemory)
        await Fixture.sync(Fixture.indexer(database, FakeLibraryReader(.explicit(assets))))
        #expect(try await Fixture.localIDs(database) == ["a00000", "a00001", "a00002"])
    }

    // MARK: Resume

    /// A kill before a batch, the undated pass, the sweep or the catch-up commits, then a relaunch, gives the
    /// same index as a build that never stopped.
    @Test(arguments: [0, 1, 2, 3, 4, 5]) func anInterruptedScanResumesToACleanBuild(seed: UInt64) async throws {
        let reader = FakeLibraryReader(.seed(.hero))
        let settings = IndexerSettings(batchSize: 50)
        let points: [IndexFaults.Point] = (0..<12).map { .scanBatch($0) } + [.undatedBatch(0), .sweep, .deltaChunk(index: 0, isLast: true)]
        var random = SplitMix(seed: seed)
        let point = points[Int(random.next() % UInt64(points.count))]

        let database = try IndexDatabase.open(.inMemory)
        let late = Fixture.photo("late", 1_790_000_000, at: Fixture.nakheel)
        let once = Once()
        await Fixture.sync(Fixture.indexer(database, reader, settings: settings, faults: IndexFaults { reached in
            // The catch-up only applies a delta when something changed during the scan.
            if case .deltaChunk = point, reached == .scanBatch(3), once() { reader.insert([late]) }
            if reached == point { throw Kill() }
        }))
        let interrupted = try await Fixture.meta(database)
        #expect(!interrupted.firstBuildDone, "killed at \(point)")
        #expect(interrupted.phase != .idle)

        let relaunched = Fixture.indexer(database, reader, settings: settings)
        await Fixture.sync(relaunched)
        #expect(await relaunched.stats.resumedScans == 1, "\(point)")
        #expect(await relaunched.stats.fullScans.isEmpty, "\(point): resumed, not restarted")

        let clean = try await Fixture.cleanBuild(of: reader, settings: settings)
        #expect(try await Fixture.assetRows(database) == Fixture.assetRows(clean), "\(point)")
        #expect(try await Fixture.dirtyDays(database) == Fixture.dirtyDays(clean), "\(point)")
        let resumed = try await Fixture.meta(database)
        let token = try reader.currentToken()
        #expect(resumed.phase == .idle)
        #expect(resumed.firstBuildDone)
        #expect(resumed.libraryToken == token)
    }

    @Test func aPausedScanResumesFromItsFrontier() async throws {
        let reader = FakeLibraryReader(.seed(.hero))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader, settings: IndexerSettings(batchSize: 50, progressInterval: .zero, pacePerBatch: .milliseconds(15)))
        let recorder = StatusRecorder(indexer.status)
        await indexer.enqueue(.sync(.launch))
        try await waitUntil { recorder.values.contains { if case .reading(let done, _) = $0.phase { done >= 100 } else { false } } }
        await indexer.pause()
        #expect(recorder.values.last?.phase == .paused)
        let paused = try await Fixture.meta(database)
        #expect(paused.phase == .dated)
        #expect(paused.frontier != nil)
        let readBeforePause = await indexer.stats.writes.inserted
        #expect(readBeforePause > 0 && readBeforePause < 561)

        await indexer.resume()
        await indexer.settled()
        recorder.cancel()
        #expect(await indexer.stats.resumedScans == 1)
        #expect(await indexer.stats.writes.inserted == 561)
        #expect(try await Fixture.assetRows(database) == Fixture.assetRows(Fixture.cleanBuild(of: reader)))
    }

    // MARK: Catch-up and sweep

    @Test func changesDuringTheScanAreCaughtUp() async throws {
        let assets = Fixture.library(30)
        let reader = FakeLibraryReader(.explicit(assets))
        let once = Once()
        // Newest first with batches of 5: batch 0 holds a00029…a00025, batch 1 a00024…a00020.
        let faults = IndexFaults { point in
            guard point == .scanBatch(2), once() else { return }
            reader.insert([Fixture.photo("new", 1_800_000_000, at: Fixture.athens)])                         // newer than the frontier
            var moved = assets[27]
            moved.facts.coordinate = Fixture.sydney                                                            // already read
            reader.update([moved])
            reader.delete(["a00022"])                                                                          // already read
            reader.hide(["a00003"])                                                                            // not read yet
        }
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader, settings: IndexerSettings(batchSize: 5), faults: faults)
        await Fixture.sync(indexer)

        let ids = try await Fixture.localIDs(database)
        #expect(ids.contains("new"))
        #expect(!ids.contains("a00022"))
        #expect(!ids.contains("a00003"), "hidden during the scan: the catch-up re-read misses it")
        #expect(try await Fixture.assetRows(database) == Fixture.assetRows(Fixture.cleanBuild(of: reader)))
        #expect(await indexer.stats.fullScans == [.firstRun: 1])
        #expect(await indexer.stats.deltas == 0, "the catch-up is part of the scan")
        let token = try reader.currentToken()
        #expect(try await Fixture.meta(database).libraryToken == token)
    }

    @Test func theSweepDeletesWhatAFullScanDidNotSee() async throws {
        let assets = Fixture.library(10)
        let reader = FakeLibraryReader(.explicit(assets))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, reader)
        await Fixture.sync(indexer)
        try await database.write { db in try db.execute(sql: "DELETE FROM dirty_day") }
        let goneDay = try await database.read { db in try Int32.fetchOne(db, sql: "SELECT day FROM asset WHERE local_id = 'a00004'") }

        reader.delete(["a00004"])
        reader.expireTokens()
        await Fixture.sync(indexer)
        #expect(await indexer.stats.fullScans[.tokenExpired] == 1)
        #expect(try await !Fixture.localIDs(database).contains("a00004"))
        #expect(try await Fixture.dirtyDays(database) == [try #require(goneDay)], "only the swept asset's day changed")
        #expect(await indexer.stats.writes.updated == 0)
    }

    // MARK: Checkpoints

    @Test func checkpointsStructureTheCompleteDaysAsTheScanGoes() async throws {
        let structure = RecordingStructurePass()
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, FakeLibraryReader(.seed(.hero)),
                                      settings: IndexerSettings(batchSize: 50, checkpointAssets: 100), structure: structure)
        let recorder = StatusRecorder(indexer.status)
        await Fixture.sync(indexer)
        recorder.cancel()

        let progressive = structure.calls.filter { !$0.final }
        #expect(progressive.count == 5, "every 100 of the 557 dated assets")
        let days = progressive.compactMap(\.daysAfter)
        #expect(days.count == 5)
        #expect(zip(days, days.dropFirst()).allSatisfy { $0 >= $1 }, "older days complete as the scan goes back")
        #expect(structure.calls.last == .init(daysAfter: nil, final: true))
        #expect(await indexer.stats.checkpoints == 5)
        #expect(try await Fixture.meta(database).version == 6, "a version per checkpoint and one at the end")
        let partial = recorder.values.filter { $0.isPartial && $0.coveredSince != nil }
        #expect(!partial.isEmpty, "searchable since the frontier while the first build runs")
    }

    @Test func theCompleteDayRuleLeavesAZoneAndBorrowingMargin() {
        // A frontier at 2024-06-15 12:00 UTC: an unread photo can be up to 14 h ahead in wall time, and borrow a
        // zone 12 h further, so days through 16 Jun stay open.
        let frontier: Int64 = 1_718_452_800
        #expect(LibraryIndexer.lastOpenDay(frontier: frontier) == LocalTime.day(year: 2024, month: 6, day: 16))
    }

    // MARK: Queue

    @Test func pendingJobsCoalesce() async throws {
        let structure = RecordingStructurePass()
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, FakeLibraryReader(.explicit(Fixture.library(8))), structure: structure)
        await indexer.pause()
        await indexer.enqueue(.sync(.launch))
        await indexer.enqueue(.sync(.libraryChanged))
        await indexer.enqueue(.restructure)
        await indexer.enqueue(.sync(.foreground))
        await indexer.settled()
        #expect(structure.calls.isEmpty, "paused: nothing runs")

        await indexer.resume()
        await indexer.settled()
        #expect(await indexer.stats.fullScans == [.firstRun: 1])
        #expect(structure.calls.filter(\.final).count == 1, "one sync covered every pending job")
    }

    @Test func aRebuildSupersedesPendingSyncs() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, FakeLibraryReader(.explicit(Fixture.library(8))))
        await indexer.pause()
        await indexer.enqueue(.sync(.launch))
        await indexer.enqueue(.rebuild)
        await indexer.resume()
        await indexer.settled()
        #expect(await indexer.stats.fullScans == [.rebuild: 1])
        #expect(try await Fixture.count(database, "asset") == 8)
    }

    @Test func aNewSubscriberGetsTheCurrentStatus() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, FakeLibraryReader(.explicit(Fixture.library(4))))
        await Fixture.sync(indexer)
        var iterator = indexer.status.makeAsyncIterator()
        let status = await iterator.next()
        #expect(status?.phase == .ready)
        #expect(status?.summary?.assets == 4)
        #expect(status?.version == 1)
        #expect(status?.lastSync == Date(timeIntervalSince1970: Fixture.now.timeIntervalSince1970.rounded(.down)))
    }

    @Test func stoppingCancelsTheJobAndEndsTheStatusStream() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.indexer(database, FakeLibraryReader(.seed(.hero)),
                                      settings: IndexerSettings(batchSize: 50, progressInterval: .zero, pacePerBatch: .milliseconds(15)))
        let stream = indexer.status
        let ended = Task { for await _ in stream {}; return true }
        let recorder = StatusRecorder(indexer.status)
        await indexer.enqueue(.sync(.launch))
        try await waitUntil { recorder.values.contains { if case .reading(let done, _) = $0.phase { done >= 50 } else { false } } }
        await indexer.stop()
        #expect(await ended.value)
        #expect(try await Fixture.meta(database).phase == .dated, "the scan stopped mid-way and can resume")
        await indexer.enqueue(.sync(.manual))
        await indexer.settled()
        #expect(try await Fixture.meta(database).phase == .dated, "a stopped indexer takes no more jobs")
        recorder.cancel()
    }
}

/// The fault the tests inject: like the app being killed before a transaction commits.
struct Kill: Error {}

/// True the first time it is called.
final class Once: Sendable {
    private let done = Mutex(false)

    func callAsFunction() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}

/// A small deterministic generator for property tests.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Polls `condition` every 5 ms for up to 5 s.
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting")
}
