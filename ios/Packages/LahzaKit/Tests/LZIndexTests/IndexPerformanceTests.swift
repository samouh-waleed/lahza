import Darwin
import Foundation
import LZCore
import LZLibrary
import Testing
@testable import LZIndex

/// 100k synthetic assets through the first build, into a temporary on-disk index (opt-in: `make perf-kit`, which
/// sets LZ_PERF=1 and builds in release). The spec's limits hold in release; a debug build only gets a sanity
/// bound, because unoptimised GRDB and SQLite bindings are several times slower.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LZ_PERF"] == "1"))
struct IndexPerformanceTests {
    #if DEBUG
    static let firstBuildLimit: Duration = .seconds(30)
    #else
    static let firstBuildLimit: Duration = .seconds(10)
    #endif
    static let memoryGrowthLimit = 150 * 1_024 * 1_024

    /// The process's peak resident size so far (`mach_task_basic_info.resident_size_max`).
    private func peakResidentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size_max) : 0
    }

    @Test func aHundredThousandAssetsBuildWithinBudget() async throws {
        let reader = FakeLibraryReader(.synthetic(FakePhotoLibraryClient(access: .full, counts: [.full: 100_000, .limited: 100])))
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            let indexer = Fixture.indexer(database, reader, clock: SystemClock())
            let peakBefore = peakResidentBytes()
            let started = ContinuousClock.now
            await Fixture.sync(indexer)
            let firstBuild = ContinuousClock.now - started
            let growth = peakResidentBytes() - peakBefore
            let summary = try await IndexReader(database: database).summary()
            let size = try await database.sizeBytes()
            await database.close()

            print("PERF first build of \(summary.assets) assets: \(firstBuild) (P0, structure pass not yet in), peak memory growth \(growth / 1_048_576) MB, index \(size / 1_048_576) MB, \(await indexer.stats.checkpoints) checkpoints")
            #expect(summary.assets == 100_000)
            #expect(firstBuild < Self.firstBuildLimit)
            #expect(growth < Self.memoryGrowthLimit)
        }
    }
}
