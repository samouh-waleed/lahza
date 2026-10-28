import Foundation
import LZGeo
import Synchronization
import Testing
@testable import LZLibrary
#if canImport(Photos)
import Photos
#endif

/// The fake library reader (scans, deltas, scripted changes, access), the PhotoKit fetch rules,
/// the fake image provider and the seed's fake Apple Maps.
@Suite struct LibraryReaderTests {
    /// Every batch a scan hands over, in order.
    private func scan(_ reader: FakeLibraryReader, frontier: Date? = nil, batchSize: Int = 100) async throws -> [[LibraryAsset]] {
        let batches = Mutex<[[LibraryAsset]]>([])
        try await reader.scanDated(createdAtOrBefore: frontier, batchSize: batchSize) { batch in batches.withLock { $0.append(batch) } }
        return batches.withLock { $0 }
    }

    private func photo(_ id: String, _ seconds: TimeInterval?) -> LibraryAsset {
        LibraryAsset(id: id, facts: AssetFacts(kind: .photo, creationDate: seconds.map { Date(timeIntervalSince1970: $0) }))
    }

    // MARK: Scans

    @Test func theSeedReaderScansNewestFirstInBatches() async throws {
        let reader = FakeLibraryReader(.seed(.hero))
        #expect(await reader.estimatedCount() == 561)
        let batches = try await scan(reader, batchSize: 100)
        #expect(batches.map(\.count) == [100, 100, 100, 100, 100, 57])
        let dates = batches.joined().compactMap(\.facts.creationDate)
        #expect(dates.count == 557)
        #expect(dates == dates.sorted(by: >))

        let frontier = try #require(SeedScenario.hero.items(.greece).first?.date)
        let resumed = try await scan(reader, frontier: frontier, batchSize: 50).joined()
        #expect(resumed.allSatisfy { ($0.facts.creationDate ?? .distantFuture) <= frontier })
        #expect(resumed.count == dates.filter { $0 <= frontier }.count)
        #expect(resumed.first?.facts.creationDate == frontier, "the frontier itself is read again")

        let undated = Mutex<[LibraryAsset]>([])
        try await reader.scanUndated(batchSize: 3) { batch in undated.withLock { $0 += batch } }
        #expect(undated.withLock { $0.map(\.id) } == ["seed/0558", "seed/0559", "seed/0560", "seed/0561"])
    }

    @Test func aScanReadsTheLibraryAsItWasWhenItStarted() async throws {
        let reader = FakeLibraryReader(.explicit([photo("a", 100), photo("b", 200), photo("c", 300)]))
        let token = try reader.currentToken()
        let seen = Mutex<[String]>([])
        try await reader.scanDated(createdAtOrBefore: nil, batchSize: 1) { batch in
            seen.withLock { $0 += batch.map(\.id) }
            if batch.first?.id == "c" { reader.insert([self.photo("d", 400)]) }
        }
        #expect(seen.withLock { $0 } == ["c", "b", "a"])
        guard case .changes(let inserted, _, _, _) = await reader.delta(since: token) else {
            Issue.record("expected changes")
            return
        }
        #expect(inserted == ["d"])
    }

    @Test func aCancelledScanStopsBetweenBatches() async throws {
        let reader = FakeLibraryReader(.seed(.hero))
        let batches = Mutex(0)
        let task = Task {
            try await reader.scanDated(createdAtOrBefore: nil, batchSize: 10) { _ in
                batches.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(batches.withLock { $0 } == 1)
    }

    // MARK: Deltas

    @Test func scriptedChangesComeBackAsDeltas() async throws {
        let reader = FakeLibraryReader(.explicit([photo("a", 100), photo("b", 200), photo("c", 300)]))
        let start = try reader.currentToken()
        #expect(await reader.delta(since: start) == .unchanged(start))

        reader.insert([photo("d", 400)])
        reader.update([photo("a", 150), photo("missing", 1)])
        reader.delete(["b"])
        guard case .changes(let inserted, let updated, let deleted, let through) = await reader.delta(since: start) else {
            Issue.record("expected changes")
            return
        }
        #expect(inserted == ["d"])
        #expect(updated == ["a"], "an update of an unknown id is not a change")
        #expect(deleted == ["b"])
        #expect(through == (try reader.currentToken()))
        #expect(await reader.delta(since: through) == .unchanged(through))
        let reread = try await reader.assets(withIDs: ["a", "b", "d"])
        #expect(reread.map(\.id) == ["a", "d"])
        #expect(reread.first?.facts.creationDate == Date(timeIntervalSince1970: 150))
    }

    @Test func hiddenAssetsAreUpdatesThatReadsMiss() async throws {
        let reader = FakeLibraryReader(.explicit([photo("a", 100), photo("b", 200)]))
        let start = try reader.currentToken()
        reader.hide(["a"])
        #expect(await reader.delta(since: start) == .changes(inserted: [], updated: ["a"], deleted: [], through: try reader.currentToken()))
        #expect(try await reader.assets(withIDs: ["a", "b"]).map(\.id) == ["b"])
        #expect(try await scan(reader).joined().map(\.id) == ["b"])
        #expect(await reader.estimatedCount() == 1)
        let hidden = try reader.currentToken()
        reader.unhide(["a"])
        #expect(await reader.delta(since: hidden) == .changes(inserted: [], updated: ["a"], deleted: [], through: try reader.currentToken()))
        #expect(try await reader.assets(withIDs: ["a"]).map(\.id) == ["a"])
        #expect(reader.allAssets.count == 2)
    }

    @Test func expiredTokensUnavailableDetailsAndForeignTokensNeedAFullScan() async throws {
        let reader = FakeLibraryReader(.explicit([photo("a", 100)]))
        let old = try reader.currentToken()
        reader.insert([photo("b", 200)])
        reader.expireTokens()
        #expect(await reader.delta(since: old) == .needsFullScan(.tokenExpired))
        let fresh = try reader.currentToken()
        #expect(await reader.delta(since: fresh) == .unchanged(fresh))

        reader.setDetailsUnavailable(true)
        reader.delete(["a"])
        #expect(await reader.delta(since: fresh) == .needsFullScan(.detailsUnavailable))
        reader.setDetailsUnavailable(false)
        #expect(await reader.delta(since: fresh) == .changes(inserted: [], updated: [], deleted: ["a"], through: try reader.currentToken()))

        #expect(await reader.delta(since: LibraryToken(data: Data([1, 2, 3]))) == .needsFullScan(.undecodableToken))
    }

    // MARK: Access

    @Test func withoutAccessNothingIsRead() async throws {
        let reader = FakeLibraryReader(.seed(.hero), access: .denied)
        #expect(reader.access() == .denied)
        #expect(throws: LibraryReaderError.noAccess) { try reader.currentToken() }
        await #expect(throws: LibraryReaderError.noAccess) { try await self.scan(reader) }
        await #expect(throws: LibraryReaderError.noAccess) { try await reader.assets(withIDs: ["seed/0001"]) }
        #expect(await reader.estimatedCount() == 0)
        #expect(await reader.delta(since: LibraryToken(data: Data())) == .needsFullScan(.historyFailed))
        reader.setAccess(.full)
        #expect(await reader.estimatedCount() == 561)
    }

    @Test func limitedAccessShowsOnlyTheSelection() async throws {
        let reader = FakeLibraryReader(.seed(.hero), access: .limited)
        #expect(await reader.estimatedCount() == 0)
        reader.setLimitedSelection(["seed/0001", "seed/0002", "seed/0558"])
        #expect(await reader.estimatedCount() == 3)
        #expect(try await scan(reader).joined().map(\.id) == ["seed/0002", "seed/0001"])
        #expect(try await reader.assets(withIDs: ["seed/0001", "seed/0003"]).map(\.id) == ["seed/0001"])
    }

    @Test func theSyntheticLibraryFollowsItsClient() async throws {
        let client = FakePhotoLibraryClient(access: .notDetermined)
        let reader = FakeLibraryReader(.synthetic(client))
        #expect(reader.access() == .notDetermined)
        #expect(await reader.estimatedCount() == 0)
        client.setAccess(.full)
        #expect(await reader.estimatedCount() == 12_480)
        reader.setAccess(.limited)
        #expect(client.access == .limited)
        #expect(await reader.estimatedCount() == 36)
        client.setCount(48, for: .limited)
        #expect(await reader.estimatedCount() == 48)
        let ids = try await scan(reader).joined().map(\.id)
        #expect(ids.allSatisfy { $0.hasPrefix("synthetic/") })
    }

    @Test func availabilityReportsAnUnavailableLibrary() async {
        let reader = FakeLibraryReader(.empty)
        let stream = reader.availability()
        reader.makeUnavailable()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .unavailable)
    }

    // MARK: Fetch rules

    #if canImport(Photos)
    @Test func fetchRulesKeepHiddenAndSharedAlbumsOut() throws {
        let plain = LibraryFetchRules.options()
        #expect(!plain.includeHiddenAssets)
        #expect(plain.includeAssetSourceTypes == .typeUserLibrary)
        #expect(!plain.includeAllBurstAssets)
        #expect(!plain.wantsIncrementalChangeDetails)
        #expect(plain.sortDescriptors == nil)
        #expect(plain.predicate == nil)
        #expect(LibraryFetchRules.options(allBurstFrames: true).includeAllBurstAssets)

        let frontier = Date(timeIntervalSince1970: 1_750_000_000)
        let resume = LibraryFetchRules.options(sortedNewestFirst: true, createdAtOrBefore: frontier)
        let sort = try #require(resume.sortDescriptors?.first)
        #expect(sort.key == "creationDate" && !sort.ascending)
        let predicate = try #require(resume.predicate as? NSComparisonPredicate)
        #expect(predicate.leftExpression.keyPath == "creationDate")
        #expect(predicate.predicateOperatorType == .lessThanOrEqualTo)
        #expect(predicate.rightExpression.constantValue as? Date == frontier)
    }
    #endif

    // MARK: Images and maps

    @Test func fakeImagesDrawSeedArtworkAndScriptedFailures() async throws {
        let images = FakeAssetImageProvider(dates: ["x": Date(timeIntervalSince1970: 1_700_000_000)], missing: ["gone"], inCloud: ["cloud"])
        guard case .image(let thumbnail) = await images.thumbnail(for: "seed/0001", side: 120) else {
            Issue.record("expected a seed thumbnail")
            return
        }
        #expect(min(thumbnail.width, thumbnail.height) == 120)
        guard case .image(let display) = await images.displayImage(for: "x", maxPixel: 400) else {
            Issue.record("expected a placeholder")
            return
        }
        #expect(max(display.width, display.height) == 400)
        guard case .missing = await images.thumbnail(for: "gone", side: 64) else {
            Issue.record("expected missing")
            return
        }
        guard case .inCloud = await images.displayImage(for: "cloud", maxPixel: 64) else {
            Issue.record("expected in cloud")
            return
        }
        images.startCaching(["a", "b", "c"], side: 64)
        images.stopCaching(["b"], side: 64)
        #expect(images.cachedIDs == ["a", "c"])
        images.stopAll()
        #expect(images.cachedIDs.isEmpty)
    }

    @Test func seedMapsAnswerTheHeroQuestions() async throws {
        let maps = SeedMaps.client()
        let park = try await maps.pointsOfInterest(near: SeedPlace.alNakheelPark.coordinate, radius: 300, categories: PlaceCategory.areas)
        #expect(park.map(\.name) == ["Al-Nakheel Park"])
        // Dubai Mall is a store, so an area-only request never names it.
        let mall = try? await maps.pointsOfInterest(near: SeedPlace.dubaiMall.coordinate, radius: 200, categories: PlaceCategory.areas)
        #expect(mall?.contains { $0.name == "Dubai Mall" } != true)
        #expect(try await maps.reverseGeocode(SeedPlace.fira.coordinate)?.cityName == "Thira")
        #expect(try await maps.reverseGeocode(SeedPlace.oia.coordinate)?.cityName == "Oia")
        #expect(try await maps.reverseGeocode(SeedPlace.desertCamp.coordinate) == MapAddress(cityName: "Rumah", countryCode: "SA"))
        #expect(try await maps.search("Salam Park", near: nil).compactMap(\.cityName) == ["Riyadh", "Dubai"])
        #expect(try await maps.search("al-nakheel park", near: nil).count == 2)
        let santorini = try #require(try await maps.search("Santorini", near: nil).first)
        #expect(santorini.kind == .physicalFeature && santorini.boundingRadius == 10_000)
        #expect(try await maps.search("Sufra Grill", near: nil).first?.category == .restaurant)
        #expect(try await maps.search("Paris", near: nil).first?.countryCode == "FR")
        await #expect(throws: MapsError.notFound) { try await maps.search("shawarma", near: nil) }
    }
}
