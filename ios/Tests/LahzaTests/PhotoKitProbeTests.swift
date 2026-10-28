import Foundation
import LZGeo
import LZLibrary
import Photos
import Synchronization
import Testing

/// What importing the hero seed library into the Simulator's Photos kept (search v0 spec, PR 1
/// acceptance 3), read through ``LiveLibraryReader``. Opt-in: it needs a seeded simulator with photo
/// access, so it runs only with `LZ_SEEDED_LIBRARY=1`:
///
///     make sim-reset CONFIRM=1 && make seed-photos && make grant-photos && make probe-photos
///
/// It prints every fact it measures (lines starting "PROBE") and fails when PhotoKit stops matching
/// ``SeedCapabilities/hero``, which is where the facts are recorded.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LZ_SEEDED_LIBRARY"] == "1", "needs a seeded simulator: LZ_SEEDED_LIBRARY=1"))
struct PhotoKitProbeTests {
    private let scenario = SeedScenario.hero
    private let recorded = SeedCapabilities.hero

    private func collect(_ scan: (@escaping @Sendable ([LibraryAsset]) async throws -> Void) async throws -> Void) async throws -> [LibraryAsset] {
        let assets = Mutex<[LibraryAsset]>([])
        try await scan { batch in assets.withLock { $0 += batch } }
        return assets.withLock { $0 }
    }

    private func second(_ date: Date?) -> Int64? {
        date.map { Int64($0.timeIntervalSince1970.rounded()) }
    }

    @Test func theSeedLibraryImportedAsRecorded() async throws {
        let reader = LiveLibraryReader()
        try #require(reader.access() == .full, "Lahza needs full photo access: make grant-photos")

        // Every dated asset, newest first.
        let all = try await collect { try await reader.scanDated(createdAtOrBefore: nil, batchSize: 100, $0) }
        let dates = all.compactMap(\.facts.creationDate)
        #expect(dates == dates.sorted(by: >), "creation-date descending sort")
        let estimated = await reader.estimatedCount()

        // Map assets back to seed items by capture second (±1 s).
        var matched: [String: LibraryAsset] = [:]
        var unmatched: [LibraryAsset] = []
        for asset in all {
            if let utc = second(asset.facts.creationDate), let item = scenario.item(matchingUTC: utc), item.isInPhotoKit, matched[item.id] == nil {
                matched[item.id] = asset
            } else {
                unmatched.append(asset)
            }
        }
        let seeds = scenario.photoKitItems
        try #require(Double(matched.count) >= 0.9 * Double(seeds.filter { !$0.isVideo }.count),
                     "seed the simulator first: make seed-photos (\(matched.count) of \(seeds.count) seed items found)")

        func imported(_ items: [SeedItem]) -> Bool { !items.isEmpty && items.allSatisfy { matched[$0.id] != nil } }
        func gpsError(_ item: SeedItem) -> Double? {
            guard let expected = item.coordinate, let found = matched[item.id]?.facts.coordinate else { return nil }
            return found.distance(to: expected)
        }
        func located(_ items: [SeedItem]) -> Bool {
            let errors = items.filter(\.isLocated).map(gpsError)
            return !errors.isEmpty && errors.allSatisfy { ($0 ?? .infinity) <= 1 }
        }
        let photos = seeds.filter { [.photo, .received, .dateOnly].contains($0.media) }
        let videos = seeds.filter(\.isVideo)
        let screens = seeds.filter { $0.media == .screenshot }
        let dateErrors = seeds.compactMap { item in matched[item.id].flatMap { second($0.facts.creationDate) }.flatMap { found in item.utc.map { abs(found - $0) } } }
        let gpsErrors = seeds.compactMap(gpsError)
        let unlocatedStayUnlocated = seeds.filter { !$0.isLocated }.allSatisfy { matched[$0.id]?.facts.coordinate == nil }
        let selfies = Set(matched.filter(\.value.isSelfie).keys)
        let added = matched.values.compactMap { asset in asset.facts.addedDate.flatMap { added in asset.facts.creationDate.map { added.timeIntervalSince($0) } } }

        // The resume predicate: creationDate <= frontier, newest first.
        let frontier = try #require(dates.dropFirst(dates.count / 3).first)
        let resumed = try await collect { try await reader.scanDated(createdAtOrBefore: frontier, batchSize: 64, $0) }
        let resumedDates = resumed.compactMap(\.facts.creationDate)
        let frontierWorks = resumedDates == resumedDates.sorted(by: >) && resumedDates.allSatisfy { $0 <= frontier }
            && Set(resumed.map(\.id)) == Set(all.filter { ($0.facts.creationDate ?? .distantFuture) <= frontier }.map(\.id))

        // creationDate == nil: PhotoKit dates every import, so a correct answer is what a full walk finds.
        let undated = try await collect { try await reader.scanUndated(batchSize: 100, $0) }
        var walkedUndated = 0
        PHAsset.fetchAssets(with: LibraryFetchRules.options()).enumerateObjects { asset, _, _ in
            if asset.creationDate == nil { walkedUndated += 1 }
        }

        // By-id re-reads and the change token.
        let selfieAssets = seeds.filter(\.isSelfie).compactMap { matched[$0.id]?.id }
        let someIDs = Array(matched.values.map(\.id).sorted().prefix(16)) + selfieAssets + ["not-a-real-id"]
        let reread = try await reader.assets(withIDs: someIDs)
        let token = try reader.currentToken()
        let delta = await reader.delta(since: token)

        let measured = SeedCapabilities(
            photoDates: imported(photos), photoLocations: located(photos.filter(\.isLocated)), screenshotDates: imported(screens),
            screenshotSubtype: imported(screens) && screens.allSatisfy { matched[$0.id]?.facts.subtypes.contains(.screenshot) == true },
            selfiesAlbum: !selfies.isEmpty && selfies == Set(seeds.filter(\.isSelfie).map(\.id)),
            videoDates: imported(videos), videoLocations: imported(videos) && located(videos),
            addedDateIsImportTime: !added.isEmpty && added.allSatisfy { $0 > 86_400 },
            frontierPredicate: frontierWorks, nilDatePredicate: undated.count == walkedUndated,
            builtInSamples: unmatched.map {
                SeedCapabilities.Sample(isVideo: $0.facts.kind == .video, utc: second($0.facts.creationDate), isLocated: $0.facts.isLocated,
                                        pixelWidth: $0.facts.pixelWidth, pixelHeight: $0.facts.pixelHeight)
            }.sorted { ($0.utc ?? 0) < ($1.utc ?? 0) }
        )

        print("PROBE assets dated=\(all.count) estimated=\(estimated) undated=\(undated.count) walkedUndated=\(walkedUndated)")
        print("PROBE seed matched=\(matched.count)/\(seeds.count) photos=\(photos.filter { matched[$0.id] != nil }.count)/\(photos.count) videos=\(videos.filter { matched[$0.id] != nil }.count)/\(videos.count) screens=\(screens.filter { matched[$0.id] != nil }.count)/\(screens.count)")
        print("PROBE dateErrorMax=\(dateErrors.max() ?? -1)s gpsErrorMax=\(String(format: "%.3f", gpsErrors.max() ?? -1))m gpsChecked=\(gpsErrors.count) unlocatedStayUnlocated=\(unlocatedStayUnlocated)")
        print("PROBE located seed=\(matched.values.filter(\.facts.isLocated).count) samples=\(unmatched.filter(\.facts.isLocated).count) total=\(all.filter(\.facts.isLocated).count)")
        print("PROBE selfies=\(selfies.sorted()) addedMinusCreatedMin=\(Int(added.min() ?? 0))s frontierResumed=\(resumed.count)")
        print("PROBE reread=\(reread.count)/\(someIDs.count) rereadSelfies=\(reread.filter(\.isSelfie).count) delta=\(delta)")
        print("PROBE capabilities \(measured)")

        #expect(all.count == seeds.count + SeedScenario.builtInSampleCount, "557 seed items + the 6 samples")
        #expect(estimated == all.count + undated.count)
        #expect(unmatched.count == SeedScenario.builtInSampleCount)
        #expect(unlocatedStayUnlocated)
        #expect(Set(reread.map(\.id)) == Set(someIDs.dropLast()))
        #expect(reread.filter(\.isSelfie).count == (recorded.selfiesAlbum ? selfieAssets.count : 0), "Selfies membership on a by-id read")
        #expect(delta == .unchanged(token))
        #expect(measured == recorded, "PhotoKit no longer matches SeedCapabilities.hero")
    }
}
