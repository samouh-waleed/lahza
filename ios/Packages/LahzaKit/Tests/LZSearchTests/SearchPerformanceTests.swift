import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex
@testable import LZSearch

/// Search over 100k synthetic assets without Apple Maps (opt-in: `make perf-kit`, optimised): the 95th-percentile
/// search under 300 ms and the snapshot scan (score and tier) under 50 ms (search spec §6.9), into a temporary on-disk
/// index that is deleted afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LZ_PERF"] == "1"))
struct SearchPerformanceTests {
    /// `make perf-kit` keeps DEBUG defined, so ask the optimiser instead.
    static let isOptimized = !_isDebugAssertConfiguration()
    static let searchLimit: Duration = isOptimized ? .milliseconds(300) : .seconds(3)
    static let scanLimit: Duration = isOptimized ? .milliseconds(50) : .milliseconds(500)

    static let queries = [
        "Riyadh 2025", "Dubai", "London", "last summer", "videos", "screenshots", "trips", "weekends in Riyadh", "Ramadan 2024", "Saturday evening",
        "at home", "Eid", "3 years ago", "Jeddah last year", "summer", "selfies", "favorites", "London new year's eve", "Dubai December 2024", "2019",
    ]

    private func p95(_ samples: [Duration]) -> Duration {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
    }

    @Test func searchingAHundredThousandAssetsStaysWithinBudget() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lz-search-perf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try IndexDatabase.open(.directory(folder))
        let clock = SystemClock()
        let reader = FakeLibraryReader(.synthetic(FakePhotoLibraryClient(access: .full, counts: [.full: 100_000, .limited: 100])))
        let indexer = LibraryIndexer(database: database, reader: reader, gazetteer: SearchFixture.gazetteer, clock: clock,
                                     deviceTimeZone: { SearchFixture.riyadh })
        let built = ContinuousClock.now
        await indexer.enqueue(.sync(.launch))
        await indexer.settled()
        let buildTime = ContinuousClock.now - built

        let index = IndexReader(database: database)
        let snapshotStarted = ContinuousClock.now
        let snapshot = try await index.snapshot()
        let snapshotTime = ContinuousClock.now - snapshotStarted
        let maps = FakeMapsClient()
        let engine = SearchEngine(gazetteer: SearchFixture.gazetteer, maps: maps, budget: MapsBudget(clock: clock), clock: clock,
                                  network: FakeNetworkStatus(reachable: false), locale: SearchFixture.uk, deviceTimeZone: { SearchFixture.riyadh })
        for query in Self.queries { _ = try await engine.search(SearchRequest(text: query), reader: index, writer: nil) }

        var totals: [Duration] = [], scans: [Duration] = []
        var hits = 0
        for _ in 0..<5 {
            for query in Self.queries {
                let result = try await engine.search(SearchRequest(text: query), reader: index, writer: nil)
                totals.append(result.timings.total)
                scans.append(result.timings.score)
                hits = max(hits, result.totals.items)
            }
        }
        await database.close()
        let total95 = p95(totals), scan95 = p95(scans)
        print("PERF (\(Self.isOptimized ? "optimised" : "unoptimised")) search over \(snapshot.count) assets: p95 \(total95), max \(totals.max()!); "
              + "scan p95 \(scan95), max \(scans.max()!); snapshot \(snapshotTime); \(totals.count) searches, largest \(hits) items; index built in \(buildTime)")
        #expect(snapshot.count == 100_000)
        #expect(maps.calls.isEmpty)
        #expect(total95 < Self.searchLimit)
        #expect(scan95 < Self.scanLimit)
    }
}
