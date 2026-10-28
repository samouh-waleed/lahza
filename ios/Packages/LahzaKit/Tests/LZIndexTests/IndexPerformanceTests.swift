import Darwin
import Foundation
import LZCore
import LZLibrary
import Synchronization
import Testing
@testable import LZIndex

/// 100k synthetic assets through the first build (P0 and the structure pass, P0b), into a temporary on-disk index (opt-in: `make perf-kit`, which
/// sets LZ_PERF=1 and builds optimised). The spec's limits hold in an optimised build; an unoptimised run only gets
/// a sanity bound, because unoptimised GRDB bindings are several times slower.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LZ_PERF"] == "1"))
struct IndexPerformanceTests {
    /// `make perf-kit` keeps DEBUG defined (the seed library is DEBUG-only), so ask the optimiser instead.
    static let isOptimized = !_isDebugAssertConfiguration()
    static let firstBuildLimit: Duration = isOptimized ? .seconds(10) : .seconds(30)
    static let structureLimit: Duration = isOptimized ? .seconds(5) : .seconds(30)
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
            let structure = TimedStructurePass()
            let indexer = Fixture.indexer(database, reader, structure: structure, clock: SystemClock())
            let peakBefore = peakResidentBytes()
            let started = ContinuousClock.now
            await Fixture.sync(indexer)
            let firstBuild = ContinuousClock.now - started
            let growth = peakResidentBytes() - peakBefore
            let (structureTime, runs) = structure.total
            let summary = try await IndexReader(database: database).summary()

            // P0b over every day again, as after a new structure version.
            try await indexer.restructureAll()
            await indexer.settled()
            let (restructure, _) = structure.total
            let size = try await database.sizeBytes()
            await database.close()

            print("PERF (\(Self.isOptimized ? "optimised" : "unoptimised")) first build of \(summary.assets) assets: \(firstBuild) in all, P0 \(firstBuild - structureTime), P0b \(structureTime) over \(runs) runs (\(await indexer.stats.checkpoints) checkpoints); full restructure \(restructure - structureTime); \(summary.moments) moments, \(summary.trips) trips; peak memory growth \(growth / 1_048_576) MB, index \(size / 1_048_576) MB")
            #expect(summary.assets == 100_000)
            #expect(summary.moments > 0)
            #expect(firstBuild - structureTime < Self.firstBuildLimit)
            #expect(structureTime < Self.structureLimit)
            #expect(restructure - structureTime < Self.structureLimit)
            #expect(growth < Self.memoryGrowthLimit)
        }
    }
}

/// The real structure pass, timing every run.
final class TimedStructurePass: StructurePass {
    private let pass = LiveStructurePass()
    private let state = Mutex<(time: Duration, runs: Int)>((.zero, 0))

    var total: (time: Duration, runs: Int) { state.withLock { $0 } }

    func run(_ database: IndexDatabase, _ run: StructureRun) async throws -> Bool {
        let started = ContinuousClock.now
        defer { state.withLock { $0.time += ContinuousClock.now - started; $0.runs += 1 } }
        return try await pass.run(database, run)
    }
}
