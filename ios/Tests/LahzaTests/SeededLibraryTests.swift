import Foundation
import LZCore
import LZGeo
import LZIndex
import LZLibrary
import Testing

/// The search index built from real PhotoKit on the seeded Simulator (search spec §9.2): the counts, trips and
/// home base the hero scenario promises, with the seed's fake Apple Maps and Riyadh as the device zone, into a
/// temporary folder. Opt-in, like the probe:
///
///     make sim-reset CONFIRM=1 && make seed-photos
///     make verify-search
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["LZ_SEEDED_LIBRARY"] == "1", "needs a seeded simulator: LZ_SEEDED_LIBRARY=1"))
struct SeededLibraryTests {
    private let scenario = SeedScenario.hero

    @Test func theIndexOfTheSeededLibraryMatchesTheScenario() async throws {
        let reader = LiveLibraryReader()
        try #require(reader.access() == .full, "Lahza needs full photo access: make grant-photos")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("seeded-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let clock = SystemClock()
        let store = IndexStore(IndexDependencies(
            location: .directory(base), reader: reader, gazetteer: try Gazetteer.bundled(), maps: SeedMaps.client(),
            budget: MapsBudget(perMinute: 60_000, capacity: 10_000, clock: clock), clock: clock, network: FakeNetworkStatus(reachable: true),
            kv: InMemoryKeyValueStore(), deviceTimeZone: { TimeZone(identifier: "Asia/Riyadh")! }, changes: { AsyncStream { $0.finish() } }))
        let started = Date()
        store.start()
        for _ in 0..<600 where store.status.phase != .ready {
            await store.settled()
            try await Task.sleep(for: .milliseconds(50))
        }
        let seconds = Date().timeIntervalSince(started)
        print("SEEDED ready after \(String(format: "%.1f", seconds)) s")
        await store.placeNamesSettled()
        #expect(store.status.phase == .ready)
        #expect(seconds < 30, "Ready in under 30 s (acceptance 3)")

        let summary = try #require(store.status.summary)
        let samples = SeedCapabilities.hero.builtInSamples
        try #require(summary.assets >= scenario.expectedPhotoKitCount, "seed the simulator first: make seed-photos (\(summary.assets) items)")
        #expect(summary.assets == scenario.expectedPhotoKitCount + samples.count)
        #expect(summary.located == SeedCapabilities.hero.expectedLocatedCount(in: scenario) + samples.count(where: \.isLocated))
        #expect(summary.videos == scenario.photoKitItems.count(where: \.isVideo) + samples.count(where: \.isVideo))

        let index = try #require(store.reader)
        let trips = try await index.trips().sorted { $0.startDay < $1.startDay }
        #expect(trips.map(\.label) == scenario.trips.map(\.name))
        #expect(trips.map(\.startDay) == scenario.trips.map(\.firstDay))
        #expect(trips.map(\.endDay) == scenario.trips.map(\.lastDay))
        let home = try #require(try await index.homeBase(year: nil))
        #expect(home.center.distance(to: scenario.home.coordinate) < 150)
        #expect(home.countryCode == "SA")
        print("SEEDED \(summary.assets) items, \(summary.located) located, \(summary.moments) moments, \(trips.count) trips, home \(home.year)")
    }
}
