import Foundation
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex

/// The index as screens see it: access opens and purges it, Delete index and Build again, the scene phase,
/// the Apple Maps toggle, library changes; and the Moments tab's pages.
@MainActor @Suite struct IndexStoreTests {
    private func dependencies(_ reader: FakeLibraryReader, location: IndexLocation = .inMemory, kv: any KeyValueStore = InMemoryKeyValueStore(),
                              maps: any MapsClient = SeedMaps.client(), network: any NetworkStatus = FakeNetworkStatus(reachable: true),
                              changes: FakePhotoLibraryClient? = nil) -> IndexDependencies {
        let clock = SystemClock()
        return IndexDependencies(location: location, reader: reader, gazetteer: Fixture.gazetteer, maps: maps,
                                 budget: MapsBudget(perMinute: 60_000, capacity: 10_000, clock: clock), clock: clock, network: network, kv: kv,
                                 deviceTimeZone: { Fixture.riyadh }, changes: { changes?.changes() ?? AsyncStream { $0.finish() } },
                                 changeDebounce: .milliseconds(20))
    }

    /// Waits up to 2 s for `condition`.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static let library = (0..<30).map { Fixture.photo("p\($0)", StructureTests.utc(2026, 9, 1 + $0, 17), at: Fixture.nakheel) }

    @Test func grantingAccessBuildsTheIndexAndRevokingPurgesIt() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let reader = FakeLibraryReader(.explicit(Self.library), access: .denied)
            let store = IndexStore(dependencies(reader, location: .directory(url)))
            #expect(store.status.phase == .off(.noAccess))
            store.start()
            await store.settled()
            #expect(store.status.phase == .off(.noAccess))
            #expect(store.reader == nil)

            reader.setAccess(.full)
            store.accessChanged()
            await store.settled()
            #expect(store.status.phase == .ready)
            #expect(store.status.summary?.assets == 30)
            #expect(store.version > 0)
            #expect(IndexDatabase.exists(.directory(url)))
            let reader1 = try #require(store.reader)
            #expect(try await reader1.summary().moments == 30)

            reader.setAccess(.denied)
            store.accessChanged()
            await store.settled()
            #expect(store.status.phase == .off(.noAccess))
            #expect(store.reader == nil)
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("Index").path), "the whole folder is gone")
            await #expect(throws: IndexError.closed) { try await reader1.summary() }
        }
    }

    @Test func anUnreadableLaunchPurgesAnIndexLeftOnDisk() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let reader = FakeLibraryReader(.explicit(Self.library), access: .full)
            let first = IndexStore(dependencies(reader, location: .directory(url)))
            first.start()
            await first.settled()
            #expect(IndexDatabase.exists(.directory(url)))

            // iOS relaunches the app already denied: no transition to see, only the state.
            reader.setAccess(.denied)
            let relaunched = IndexStore(dependencies(reader, location: .directory(url)))
            relaunched.start()
            await relaunched.settled()
            #expect(relaunched.status.phase == .off(.noAccess))
            #expect(!IndexDatabase.exists(.directory(url)))
        }
    }

    @Test func aDamagedIndexIsReopenedRebuiltAndReadAgain() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let kv = InMemoryKeyValueStore()
            let store = IndexStore(dependencies(FakeLibraryReader(.explicit(Self.library)), location: .directory(url), kv: kv))
            store.start()
            await store.settled()
            let before = try #require(store.reader)
            #expect(store.status.phase == .ready)

            // A job hit SQLITE_CORRUPT: the marker asks the next open to rebuild.
            let database = try IndexDatabase.open(.directory(url))
            database.noteCorruption()
            await database.close()
            #expect(database.needsRebuild)
            await store.repair()
            await store.settled()
            #expect(store.status.phase == .ready)
            #expect(store.status.summary?.assets == 30)
            #expect(store.reader?.generation != before.generation, "a new session")
            #expect(!database.needsRebuild, "the open rebuilt the file")
        }
    }

    @Test func deleteIndexStaysOffUntilBuildAgain() async throws {
        let kv = InMemoryKeyValueStore()
        let store = IndexStore(dependencies(FakeLibraryReader(.explicit(Self.library)), kv: kv))
        store.start()
        await store.settled()
        #expect(store.status.phase == .ready)

        await store.deleteIndex()
        #expect(store.status.phase == .off(.deletedByUser))
        #expect(store.reader == nil)
        #expect(kv.string(forKey: IndexStore.pausedKey) == "1")

        // Still off at the next launch.
        let relaunched = IndexStore(dependencies(FakeLibraryReader(.explicit(Self.library)), kv: kv))
        relaunched.start()
        await relaunched.settled()
        #expect(relaunched.status.phase == .off(.deletedByUser))

        relaunched.buildAgain()
        await relaunched.settled()
        #expect(relaunched.status.phase == .ready)
        #expect(relaunched.status.summary?.assets == 30)
        #expect(kv.string(forKey: IndexStore.pausedKey) == nil)
    }

    @Test func placeNamesRunOnlyWhileOpenAndSwitchedOn() async throws {
        let network = FakeNetworkStatus(reachable: false)
        let store = IndexStore(dependencies(FakeLibraryReader(.seed(.hero)), network: network))
        store.start()
        await store.settled()
        #expect(await eventually { store.status.placeNames.state == .waitingForNetwork })

        store.setSceneActive(false)
        await store.settled()
        #expect(store.status.phase == .paused)
        #expect(store.status.placeNames.state == .backgrounded)

        store.setSceneActive(true)
        network.setReachable(true)
        await store.placeNamesSettled()
        #expect(store.status.phase == .ready)
        #expect(store.status.placeNames.state == .done)
        #expect(store.status.placeNames.named > 0)
        let labels = try await store.reader?.moments(after: nil, limit: 600).compactMap(\.label) ?? []
        #expect(labels.filter { $0 == "Al-Nakheel Park" }.count == 10)

        store.setAppleMapsNames(false)
        #expect(store.status.placeNames.state == .off)
        #expect(!store.appleMapsNames)
    }

    @Test func theToggleIsRememberedAndOffNeverAsksAppleMaps() async throws {
        let kv = InMemoryKeyValueStore()
        let maps = SeedMaps.client()
        var store = IndexStore(dependencies(FakeLibraryReader(.seed(.hero)), kv: kv, maps: maps))
        #expect(store.appleMapsNames, "on by default")
        store.setAppleMapsNames(false)
        store = IndexStore(dependencies(FakeLibraryReader(.seed(.hero)), kv: kv, maps: maps))
        #expect(!store.appleMapsNames)
        store.start()
        await store.placeNamesSettled()
        #expect(store.status.phase == .ready)
        #expect(store.status.placeNames.state == .off)
        #expect(maps.calls.isEmpty)
    }

    @Test func libraryChangesSyncAfterADebounce() async throws {
        let photos = FakePhotoLibraryClient(access: .full)
        let reader = FakeLibraryReader(.explicit(Self.library), following: photos)
        let store = IndexStore(dependencies(reader, changes: photos))
        store.start()
        await store.settled()
        reader.insert([Fixture.photo("new", StructureTests.utc(2026, 10, 2, 9), at: Fixture.athens)])
        photos.emitChange()
        photos.emitChange()
        while store.status.summary?.assets != 31 {
            try await Task.sleep(for: .milliseconds(10))
            await store.settled()
        }
        #expect(store.status.summary?.countries == 2)
    }

    // MARK: Moments

    @Test func momentsArePagedNewestFirstInMonthSections() async throws {
        // 450 one-photo moments, a day apart.
        let assets = (0..<450).map { index -> LibraryAsset in
            let date = LocalTime.civil(day: LocalTime.day(year: 2025, month: 1, day: 1) + Int32(index))
            return Fixture.photo("m\(index)", StructureTests.utc(date.year, date.month, date.day, 12), at: Fixture.nakheel)
        }
        let reader = FakeLibraryReader(.explicit(assets))
        let store = IndexStore(dependencies(reader))
        let moments = MomentsStore(index: store)
        await moments.load()
        #expect(moments.sections.isEmpty, "nothing while the index is off")
        store.start()
        await store.settled()
        await moments.load()
        #expect(moments.moments.count == MomentsStore.pageSize)
        #expect(moments.hasMore)
        let newest = LocalTime.civil(day: LocalTime.day(year: 2025, month: 1, day: 1) + 449)
        #expect(moments.sections.first.map { [$0.year, $0.month] } == [newest.year, newest.month])
        #expect(moments.sections.first?.total == newest.day, "a month's total counts its unloaded moments too")
        #expect(moments.years.map(\.year) == [2026, 2025])
        #expect(moments.years.map(\.moments).reduce(0, +) == 450)
        #expect(moments.firstSection(of: 2025) == moments.sections.first { $0.year == 2025 }?.id)

        await moments.loadMore()
        await moments.loadMore()
        #expect(moments.moments.count == 450)
        #expect(!moments.hasMore)
        #expect(moments.moments.map(\.key) == moments.moments.map(\.key).sorted { ($0.day, $0.startUTC) > ($1.day, $1.startUTC) })

        // A change keeps everything loaded.
        reader.insert([Fixture.photo("late", StructureTests.utc(2026, 4, 1, 12), at: Fixture.athens)])
        await store.settled()
        await moments.indexChanged()
        #expect(moments.moments.count == 450, "the new moment is outside the page window kept")
        #expect(moments.moments.first?.key.day == LocalTime.day(year: 2025, month: 1, day: 1) + 449)
        await store.deleteIndex()
        await moments.indexChanged()
        #expect(moments.moments.isEmpty)
    }

    @Test func aTripsMomentsComeOldestFirst() async throws {
        let store = IndexStore(dependencies(FakeLibraryReader(.seed(.hero))))
        store.start()
        await store.settled()
        let moments = MomentsStore(index: store)
        await moments.load()
        #expect(moments.trips.count == 6)
        let greece = try #require(moments.trips.first { $0.label == "Greece" })
        let rows = await moments.moments(of: greece)
        #expect(rows.count == greece.momentCount)
        #expect(rows.map(\.key.day) == rows.map(\.key.day).sorted())
        #expect(rows.first?.key.day == greece.startDay)
        let first = try #require(rows.first)
        let detail = try #require(await moments.moment(first.key))
        #expect(detail.members.count == detail.moment.itemCount)
        #expect(greece.places.first == "Athens")
        #expect(!greece.places.contains("Greece"))
        #expect(greece.thumbnailLocalIDs.count == 5)
        #expect(greece.thumbnailLocalIDs.first == greece.coverLocalID)
    }

    @Test func theYearStripLoadsPagesUntilItsYear() async throws {
        let store = IndexStore(dependencies(FakeLibraryReader(.seed(.hero))))
        store.start()
        await store.settled()
        let moments = MomentsStore(index: store)
        await moments.load()
        #expect(moments.hasMore, "the hero library has more moments than a page")
        #expect(moments.years.first?.year == 2026)
        #expect(moments.years.last?.year == 2021)
        #expect(moments.firstSection(of: 2021) == nil)
        let section = try #require(await moments.loadThrough(year: 2021))
        #expect(section == moments.sections.first { $0.year == 2021 }?.id)
        #expect(moments.moments.count > MomentsStore.pageSize)
        #expect(moments.moments.allSatisfy { $0.thumbnailLocalIDs.count == min(3, $0.itemCount) })
        #expect(await moments.loadThrough(year: 2019) == nil, "a year without moments loads everything, then gives up")
        #expect(!moments.hasMore)
    }
}
