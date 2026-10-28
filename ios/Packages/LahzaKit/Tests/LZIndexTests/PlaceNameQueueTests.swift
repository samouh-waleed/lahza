import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Synchronization
import Testing
@testable import LZIndex

/// P2: the Apple Maps budget and the place-name queue, with the fake Maps client, a fixed clock and a scripted
/// network.
@Suite struct PlaceNameQueueTests {
    // MARK: Budget

    @Test func theBudgetKeepsTwoTokensForSearchAndRefillsAtItsRate() async throws {
        let clock = FixedClock(Fixture.now)
        let budget = MapsBudget(perMinute: 30, capacity: 5, interactiveReserve: 2, clock: clock)
        for _ in 0..<3 { #expect(try await budget.acquire(.background)) }
        let waiting = Task { try await budget.acquire(.background) }
        #expect(await clock.waitForSleepers(1), "background waits above the reserve")
        #expect(try await budget.acquire(.interactive))
        #expect(try await budget.acquire(.interactive))
        #expect(try await !budget.acquire(.interactive), "interactive never waits")
        await clock.advance(by: .seconds(5))
        #expect(clock.pendingSleepCount == 1, "one token every 2 s: 5 s refills 2.5, not yet 3")
        await clock.advance(by: .seconds(1))
        await clock.run()
        #expect(try await waiting.value)
    }

    @Test func throttlingBacksOffOneTwoFourUpToThirtyMinutesUntilASuccess() async throws {
        let clock = FixedClock(Fixture.now)
        let budget = MapsBudget(clock: clock)
        var minutes: [Double] = []
        for _ in 0..<7 {
            await budget.reportThrottled()
            minutes.append(try #require(await budget.backoffUntil).timeIntervalSince(Fixture.now) / 60)
        }
        #expect(minutes == [1, 2, 4, 8, 16, 30, 30])
        #expect(try await !budget.acquire(.interactive), "search doesn't ask while Apple Maps wants a pause")
        await budget.reportSuccess()
        #expect(await budget.backoffUntil == nil)
        await budget.reportThrottled()
        #expect(await budget.backoffUntil == Fixture.now.addingTimeInterval(60))
    }

    // MARK: Queue

    /// The hero seed indexed with the structure pass.
    private func seeded() async throws -> (IndexDatabase, LibraryIndexer) {
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.structured(database, FakeLibraryReader(.seed(.hero)))
        await Fixture.sync(indexer)
        return (database, indexer)
    }

    private func statuses(_ database: IndexDatabase) async throws -> [String: Int] {
        try await database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT cell, poi_status FROM cell").map { ($0["cell"] as String, $0["poi_status"] as Int) })
        }
    }

    @Test func onlyAreasAreAskedForAndOnlyTheCentroidIsSent() async throws {
        let (database, indexer) = try await seeded()
        let maps = SeedMaps.client()
        await Fixture.placeNames(database, indexer, maps: maps).run()
        let centroids = try await database.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT lat, lon FROM cell").map { Coordinate(latitude: $0["lat"], longitude: $0["lon"]) })
        }
        let needsLocality = try await database.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT lat, lon FROM cell WHERE needs_locality = 1").map { Coordinate(latitude: $0["lat"], longitude: $0["lon"]) })
        }
        var asked = 0, geocoded = 0
        for call in maps.calls {
            switch call {
            case .pointsOfInterest(let centroid, let radius, let categories):
                asked += 1
                #expect(categories == PlaceCategory.areas)
                #expect(radius == 500)
                #expect(centroids.contains(centroid), "a cell centroid, never a photo's own position")
            case .reverseGeocode(let centroid):
                geocoded += 1
                #expect(needsLocality.contains(centroid), "a reverse geocode only where the gazetteer has no city")
            case .search:
                Issue.record("place naming never searches")
            }
        }
        #expect(asked > 0)
        #expect(geocoded > 0)
        let home = GeoHash.encode(SeedPlace.home.coordinate, precision: 7)
        #expect(try await statuses(database)[home] == PlaceNameStatus.skippedHome.rawValue)
        #expect(!maps.calls.contains { call in
            if case .pointsOfInterest(let c, _, _) = call { return c.distance(to: SeedPlace.home.coordinate) < 150 }
            return false
        }, "the home is never sent")
    }

    @Test func nearbyCellsReuseANamedCellsAnswer() async throws {
        let base = StructureTests.utc(2026, 10, 1, 17)
        // Two neighbouring cells under 150 m apart in the park, each with 3 photos.
        let cell = GeoHash.encode(Fixture.nakheel, precision: 7)
        let neighbour = try #require(stride(from: 60.0, through: 140, by: 5).map { StructureTests.east(of: Fixture.nakheel, $0) }
            .first { GeoHash.encode($0, precision: 7) != cell })
        let assets = (0..<3).map { Fixture.photo("a\($0)", base + Int64($0) * 60, at: Fixture.nakheel) }
            + (0..<3).map { Fixture.photo("b\($0)", base + 86_400 + Int64($0) * 60, at: neighbour) }
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.structured(database, FakeLibraryReader(.explicit(assets)))
        await Fixture.sync(indexer)
        let maps = SeedMaps.client()
        await Fixture.placeNames(database, indexer, maps: maps).run()
        #expect(maps.calls.count == 1, "the second cell takes the first one's answer")
        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT poi_status, covered_by, p.name FROM cell JOIN place p ON p.id = cell.poi_place ORDER BY covered_by IS NULL")
                .map { [$0["poi_status"] as Int == 1 ? "named" : "?", $0["covered_by"] == nil ? "fetched" : "covered", $0["name"] as String] }
        }
        #expect(rows == [["named", "covered", "Al-Nakheel Park"], ["named", "fetched", "Al-Nakheel Park"]])
    }

    @Test func aRebuildNamesCellsFromTheCacheWithoutAskingAgain() async throws {
        let (database, indexer) = try await seeded()
        let maps = SeedMaps.client()
        await Fixture.placeNames(database, indexer, maps: maps).run()
        await indexer.settled()
        let named = try await statuses(database).filter { $0.value == PlaceNameStatus.named.rawValue }.count
        let calls = maps.calls.count

        await Fixture.sync(indexer, .rebuild)
        #expect(try await statuses(database).filter { $0.value == PlaceNameStatus.named.rawValue }.isEmpty)
        await Fixture.placeNames(database, indexer, maps: maps).run()
        await indexer.settled()
        #expect(maps.calls.count == calls, "the POI cache survives a rebuild")
        #expect(try await statuses(database).filter { $0.value == PlaceNameStatus.named.rawValue }.count == named)
        let labels = try await IndexReader(database: database).moments(after: nil, limit: 600).compactMap(\.label)
        #expect(labels.filter { $0 == "Al-Nakheel Park" }.count == 10)
    }

    @Test func nothingFoundIsAskedAgainAfterThirtyDays() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let base = StructureTests.utc(2026, 10, 1, 12)
        let indexer = Fixture.structured(database, FakeLibraryReader(.explicit((0..<3).map { Fixture.photo("p\($0)", base + Int64($0), at: Fixture.athens) })))
        await Fixture.sync(indexer)
        let clock = FixedClock(Fixture.now)
        let maps = FakeMapsClient()
        await Fixture.placeNames(database, indexer, maps: maps, clock: clock).run()
        #expect(maps.calls.count == 1)
        #expect(try await statuses(database).values.first == PlaceNameStatus.none.rawValue)
        await Fixture.placeNames(database, indexer, maps: maps, clock: clock).run()
        #expect(maps.calls.count == 1, "not before 30 days")
        clock.set(Fixture.now.addingTimeInterval(31 * 86_400))
        await Fixture.placeNames(database, indexer, maps: maps, clock: clock).run()
        #expect(maps.calls.count == 2)
    }

    @Test func otherErrorsRetryLaterAndGiveUpAfterFiveAttempts() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let base = StructureTests.utc(2026, 10, 1, 12)
        let indexer = Fixture.structured(database, FakeLibraryReader(.explicit((0..<3).map { Fixture.photo("p\($0)", base + Int64($0), at: Fixture.nakheel) })))
        await Fixture.sync(indexer)
        let clock = FixedClock(Fixture.now)
        let maps = SeedMaps.client()
        maps.setFailure(.other("MKErrorDomain 1"))
        var retries: [TimeInterval] = []
        for _ in 0..<5 {
            await Fixture.placeNames(database, indexer, maps: maps, clock: clock).run()
            let row = try await database.read { db in try Row.fetchOne(db, sql: "SELECT poi_status, attempts, retry_after FROM cell").map { [$0["poi_status"] as Int, $0["attempts"] as Int, $0["retry_after"] as Int? ?? 0] } }
            if let row, row[0] == PlaceNameStatus.retry.rawValue {
                retries.append(TimeInterval(row[2]) - clock.now.timeIntervalSince1970)
                clock.set(Date(timeIntervalSince1970: TimeInterval(row[2])))
            }
        }
        #expect(retries == [1_200, 2_400, 4_800, 9_600], "10 min × 2^attempts")
        #expect(try await statuses(database).values.first == PlaceNameStatus.gaveUp.rawValue)
        #expect(maps.calls.count == 5)
    }

    @Test func throttlingPausesTheQueueAndIsRememberedAcrossLaunches() async throws {
        let (database, indexer) = try await seeded()
        let clock = FixedClock(Fixture.now)
        let maps = SeedMaps.client()
        maps.failNext(.throttled)
        let queue = Fixture.placeNames(database, indexer, maps: maps, clock: clock, budget: MapsBudget(perMinute: 60_000, capacity: 10_000, clock: clock))
        let states = ProgressRecorder(queue.progress)
        let run = Task { await queue.run() }
        #expect(await clock.waitForSleepers(1))
        #expect(maps.calls.count == 1)
        #expect(try await database.read { db in try Meta.date(db, .mapsBackoffUntil) } == Fixture.now.addingTimeInterval(60))
        #expect(states.values.contains { $0.state == .throttled(until: Fixture.now.addingTimeInterval(60)) })

        // A new launch remembers the backoff.
        let relaunched = Fixture.placeNames(database, indexer, maps: maps, clock: clock, budget: MapsBudget(clock: clock))
        let second = Task { await relaunched.run() }
        #expect(await clock.waitForSleepers(2))
        #expect(maps.calls.count == 1, "nothing is asked during the backoff")
        second.cancel()
        await second.value

        await clock.advance(by: .seconds(61))
        await clock.run()
        await run.value
        #expect(maps.calls.count > 1)
        #expect(try await database.read { db in try Meta.date(db, .mapsBackoffUntil) } == nil, "a success resets it")
        #expect(states.values.last?.state == .done)
        states.cancel()
    }

    @Test func offlineTheQueueWaitsForTheNetwork() async throws {
        let (database, indexer) = try await seeded()
        let clock = FixedClock(Fixture.now)
        let network = FakeNetworkStatus(reachable: false)
        let maps = SeedMaps.client()
        let queue = Fixture.placeNames(database, indexer, maps: maps, clock: clock, network: network)
        let states = ProgressRecorder(queue.progress)
        let run = Task { await queue.run() }
        #expect(await clock.waitForSleepers(1))
        #expect(maps.calls.isEmpty)
        #expect(states.values.last?.state == .waitingForNetwork)
        network.setReachable(true)
        await run.value
        #expect(!maps.calls.isEmpty)
        #expect(states.values.last?.state == .done)
        #expect(states.values.last.map { $0.named > 0 && $0.named <= $0.eligible } == true)
        states.cancel()
    }

    @Test func aCancelledRequestNeverHoldsTheQueue() async throws {
        let (database, indexer) = try await seeded()
        let maps = HangingMapsClient()
        let queue = Fixture.placeNames(database, indexer, maps: maps, clock: SystemClock(),
                                       budget: MapsBudget(perMinute: 60_000, capacity: 10_000, clock: SystemClock()))
        let run = Task { await queue.run() }
        while maps.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let cancelled = ContinuousClock.now
        run.cancel()
        await run.value
        #expect(ContinuousClock.now - cancelled < .seconds(1), "MapKit ignores cancellation; the queue doesn't wait for it")
        maps.release()
    }

    @Test func placeNamingNeverOverwritesTheIndexersColumns() async throws {
        let base = StructureTests.utc(2026, 10, 1, 17)
        let reader = FakeLibraryReader(.explicit((0..<3).map { Fixture.photo("p\($0)", base + Int64($0) * 60, at: Fixture.nakheel) }))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.structured(database, reader)
        await Fixture.sync(indexer)
        // While Apple Maps answers, more photos land in the same cell and the indexer recounts it.
        let maps = InterleavingMapsClient(SeedMaps.client()) {
            reader.insert((3..<7).map { Fixture.photo("p\($0)", base + Int64($0) * 60, at: Fixture.nakheel) })
            await Fixture.sync(indexer, .sync(.libraryChanged))
        }
        await Fixture.placeNames(database, indexer, maps: maps).run()
        await indexer.settled()
        let row = try await database.read { db in try Row.fetchOne(db, sql: "SELECT photo_count, poi_status FROM cell").map { [$0["photo_count"] as Int, $0["poi_status"] as Int] } }
        #expect(row == [7, PlaceNameStatus.named.rawValue], "the indexer's count and the queue's name both stand")
    }
}

/// Collects a progress stream's values in the background.
final class ProgressRecorder: Sendable {
    private let state = Mutex<[PlaceNameProgress]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ stream: AsyncStream<PlaceNameProgress>) {
        let listener = Task { [weak self] in
            for await value in stream { self?.state.withLock { $0.append(value) } }
        }
        task.withLock { $0 = listener }
    }

    var values: [PlaceNameProgress] { state.withLock { $0 } }

    func cancel() { task.withLock { $0?.cancel() } }
}

/// A Maps client whose calls never return on their own and ignore cancellation, like MapKit's.
final class HangingMapsClient: MapsClient {
    private let continuations = Mutex<[CheckedContinuation<Void, Never>]>([])

    var waiting: Int { continuations.withLock { $0.count } }

    /// Lets every hanging call return (at the end of a test).
    func release() {
        for continuation in continuations.withLock({ list in defer { list = [] }; return list }) { continuation.resume() }
    }

    private func hang() async {
        await withCheckedContinuation { continuation in continuations.withLock { $0.append(continuation) } }
    }

    func pointsOfInterest(near c: Coordinate, radius: Double, categories: Set<PlaceCategory>) async throws(MapsError) -> [MapPlace] {
        await hang()
        throw .notFound
    }

    func reverseGeocode(_ c: Coordinate) async throws(MapsError) -> MapAddress? {
        await hang()
        return nil
    }

    func search(_ text: String, near region: GeoRegion?) async throws(MapsError) -> [MapPlace] {
        await hang()
        return []
    }
}

/// Runs `between` once, during the first points-of-interest call, then answers from `base`.
final class InterleavingMapsClient: MapsClient {
    private let base: FakeMapsClient
    private let between: @Sendable () async -> Void
    private let ran = Mutex(false)

    init(_ base: FakeMapsClient, between: @escaping @Sendable () async -> Void) {
        self.base = base
        self.between = between
    }

    func pointsOfInterest(near c: Coordinate, radius: Double, categories: Set<PlaceCategory>) async throws(MapsError) -> [MapPlace] {
        if !ran.withLock({ ran in defer { ran = true }; return ran }) { await between() }
        return try await base.pointsOfInterest(near: c, radius: radius, categories: categories)
    }

    func reverseGeocode(_ c: Coordinate) async throws(MapsError) -> MapAddress? { try await base.reverseGeocode(c) }

    func search(_ text: String, near region: GeoRegion?) async throws(MapsError) -> [MapPlace] { try await base.search(text, near: region) }
}
