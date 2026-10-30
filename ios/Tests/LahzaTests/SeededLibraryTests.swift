import Foundation
import LZCore
import LZGeo
import LZIndex
import LZLibrary
import LZSearch
import Photos
import Testing

/// The search index built from real PhotoKit on the seeded Simulator (search spec §9.2): the counts, trips and
/// home base the hero scenario promises, with the seed's fake Apple Maps and Riyadh as the device zone, into a
/// temporary folder; then the search goldens (HeroSuite) whose facts PhotoKit keeps. Opt-in, like the probe:
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

        // The goldens over real PhotoKit, at the spec's fixed now (a case whose fact didn't import is skipped).
        let maps = SeedMaps.client()
        let fixed = FixedClock(HeroSuite.now)
        let engine = SearchEngine(gazetteer: try Gazetteer.bundled(), maps: maps, budget: MapsBudget(clock: fixed), clock: fixed,
                                  network: FakeNetworkStatus(reachable: true), locale: HeroSuite.locale,
                                  deviceTimeZone: { TimeZone(identifier: "Asia/Riyadh")! })
        let outcomes = try await HeroSuite.run(engine: engine, reader: index, writer: store.writer, facts: .photoKit(.hero)) {
            maps.calls.count { if case .search = $0 { true } else { false } }
        }
        for outcome in outcomes { print("SEEDED hero \(outcome)") }
        let ran = outcomes.filter { $0.skipped == nil }
        print("SEEDED HeroSuite \(ran.count(where: \.passed))/\(ran.count) pass, \(outcomes.count - ran.count) skipped")
        for outcome in ran where !outcome.passed { Issue.record("\(outcome)") }
    }

    /// The viewer reads every seed file from the iPhone, network off: a screen-size image for each photo and video
    /// (never "Full quality is in iCloud"), and a player for each video.
    @Test func theViewerReadsEverySeedFileFromTheIPhone() async throws {
        try #require(LiveLibraryReader().access() == .full, "Lahza needs full photo access: make grant-photos")
        var ids: [String] = [], videos: Set<String> = []
        PHAsset.fetchAssets(with: LibraryFetchRules.options()).enumerateObjects { asset, _, _ in
            guard LibraryFetchRules.admits(asset) else { return }
            ids.append(asset.localIdentifier)
            if asset.mediaType == .video { videos.insert(asset.localIdentifier) }
        }
        try #require(ids.count >= scenario.expectedPhotoKitCount, "seed the simulator first: make seed-photos (\(ids.count) items)")
        let images = LiveAssetImageProvider(), loader = LiveVideoLoader()
        var local = 0, reduced = 0, inCloud = 0, missing = 0, playable = 0
        for id in ids {
            switch await images.displayImage(for: id, maxPixel: 1_320) {
            case .image: local += 1
            case .reduced: reduced += 1
            case .inCloud: inCloud += 1
            case .missing: missing += 1
            }
            if videos.contains(id), case .item = await loader.playerItem(for: id) { playable += 1 }
        }
        print("SEEDED viewer \(local)/\(ids.count) images local, \(reduced) reduced, \(inCloud) in iCloud, \(missing) missing; \(playable)/\(videos.count) videos play")
        #expect(local == ids.count)
        #expect(playable == videos.count)
    }
}
