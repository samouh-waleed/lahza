import Foundation
import Testing
@testable import LZIndex

/// Scoring a query against 100k stored 768-d vectors (opt-in: `make perf-kit`, optimised), in a temporary on-disk
/// index that is deleted afterwards. docs/architecture.md estimated about 4.5 ms on a Mac before the 16-bit file.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LZ_PERF"] == "1"))
struct VectorStorePerformanceTests {
    static let isOptimized = !_isDebugAssertConfiguration()
    static let count = 100_000
    static let dimension = 768

    /// Deterministic pseudo-random unit-ish vectors (a linear congruential generator, no Foundation randomness).
    private func vectors(_ count: Int, seed: UInt64) -> [[Float]] {
        var state = seed
        return (0..<count).map { _ in
            (0..<Self.dimension).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Float(Int64(bitPattern: state >> 11) % 2001 - 1000) / 1000
            }
        }
    }

    @Test func scoringAHundredThousandVectorsIsQuick() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lz-vector-perf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try IndexDatabase.open(.directory(folder))
        let store = try await VectorStore.open(database, modelID: "perf", dimension: Self.dimension)

        let written = ContinuousClock.now
        for start in stride(from: 0, to: Self.count, by: 2_000) {
            let batch = vectors(2_000, seed: UInt64(start + 1))
            try await store.upsert(batch.enumerated().map { VectorEntry(assetID: Int64(start + $0.offset + 1), vector: $0.element) })
        }
        let writeTime = ContinuousClock.now - written

        let queries = vectors(21, seed: 999)
        _ = try await store.scores(for: queries[0])
        var samples: [Duration] = []
        for query in queries.dropFirst() {
            let started = ContinuousClock.now
            let scores = try await store.scores(for: query)
            samples.append(ContinuousClock.now - started)
            #expect(scores.assetIDs.count == Self.count)
        }
        samples.sort()
        let p95 = samples[Int((Double(samples.count) * 0.95).rounded(.up)) - 1]
        let size = try FileManager.default.attributesOfItem(atPath: store.url.path)[.size] as? Int ?? 0
        print("PERF (\(Self.isOptimized ? "optimised" : "unoptimised")) vectors: \(Self.count) × \(Self.dimension) scored in median "
              + "\(samples[samples.count / 2]), p95 \(p95); written in \(writeTime); file \(size / 1_000_000) MB")
        #expect(p95 < (Self.isOptimized ? .milliseconds(100) : .seconds(2)))
        await database.close()
    }
}
