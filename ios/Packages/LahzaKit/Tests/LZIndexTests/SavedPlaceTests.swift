import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex

/// Saved places (search spec §7.4, §2.2–2.4): each write is one transaction mirrored into `place` (kind 6) with its
/// names, the days around it restructured (moment labels read the saved name), Rebuild keeps them, and the home
/// choice (a saved place, a night place, the estimate or none) drives home bases and trips.
@Suite struct SavedPlaceTests {
    /// The hero seed's index with Apple Maps names, and a writer that asks for a restructure as the session's does.
    private struct Hero {
        let database: IndexDatabase
        let indexer: LibraryIndexer
        let reader: IndexReader
        let writer: UserDataWriter

        init() async throws {
            database = try IndexDatabase.open(.inMemory)
            let indexer = Fixture.structured(database, FakeLibraryReader(.seed(.hero)))
            self.indexer = indexer
            await Fixture.sync(indexer)
            await Fixture.placeNames(database, indexer, maps: SeedMaps.client()).run()
            await indexer.settled()
            reader = IndexReader(database: database)
            writer = UserDataWriter(database: database, clock: FixedClock(Fixture.now), changed: { await indexer.enqueue(.restructure) })
        }

        /// The keys of the moments Apple Maps labelled with the park: the ten nakheel sessions.
        func nakheelKeys() async throws -> [MomentKey] {
            try await reader.moments(after: nil, limit: 500).filter { $0.label == "Al-Nakheel Park" }.map(\.key)
        }

        func labels(_ keys: [MomentKey]) async throws -> [String?] {
            let moments = try await reader.moments(after: nil, limit: 500)
            return keys.map { key in moments.first { $0.key == key }?.label ?? "gone" }
        }

        /// A nakheel moment's centre (where Save place saves it).
        func nakheelCenter() async throws -> Coordinate {
            let key = try #require(try await nakheelKeys().first)
            return try #require(try await reader.moment(key)?.moment.center)
        }
    }

    @Test func savingMirrorsThePlaceAndRelabelsItsMoments() async throws {
        let hero = try await Hero()
        let keys = try await hero.nakheelKeys()
        #expect(keys.count == 10)
        let center = try await hero.nakheelCenter()
        #expect(try await hero.reader.countWithin(center, radius: 250) == 85, "the sheet's live count: 83 located and 2 borrowed")

        let versionBefore = try await hero.reader.indexVersion()
        let id = try await hero.writer.savePlace(name: "  My   pitch ", center: center, radius: 250, isHome: false)
        await hero.indexer.settled()
        #expect(try await hero.reader.indexVersion() > versionBefore)

        let saved = try await hero.reader.savedPlaces()
        #expect(saved.map(\.name) == ["My pitch"], "trimmed and single-spaced")
        #expect(saved.first?.radius == 250 && saved.first?.isHome == false)
        struct Mirror: Sendable {
            var kind: Int, category: String?, radius: Double?, source: Int, photos: Int, names: [String]
        }
        let mirror = try await hero.database.read { db -> Mirror? in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, kind, category, radius_m, source, photo_count FROM place WHERE key = ?",
                                             arguments: [PlaceKey.saved(id)]) else { return nil }
            return Mirror(kind: row["kind"], category: row["category"], radius: row["radius_m"], source: row["source"], photos: row["photo_count"],
                          names: try String.fetchAll(db, sql: "SELECT name FROM place_name WHERE place_id = ? ORDER BY name", arguments: [row["id"] as Int64]))
        }
        #expect(mirror?.kind == PlaceKind.saved.rawValue && mirror?.category == "saved" && mirror?.radius == 250 && mirror?.source == 3)
        #expect(mirror?.photos ?? 0 >= 80, "counted from the cells inside it at the restructure")
        #expect(mirror?.names == ["my pitch", "pitch"])
        #expect(try await hero.reader.searchPlaces("pitch", limit: 3).first?.name == "My pitch", "found by name")
        #expect(try await hero.labels(keys) == Array(repeating: "My pitch", count: 10), "every nakheel moment reads the saved name")
        #expect(try await Fixture.count(hero.database, "dirty_day") == 0)
    }

    @Test func renameRadiusAndDeleteFollowThrough() async throws {
        let hero = try await Hero()
        let keys = try await hero.nakheelKeys()
        let center = try await hero.nakheelCenter()
        let id = try await hero.writer.savePlace(name: "My pitch", center: center, radius: 250, isHome: false)
        await hero.indexer.settled()

        try await hero.writer.renamePlace(id, to: "Saturday football")
        await hero.indexer.settled()
        #expect(try await hero.reader.savedPlaces().map(\.name) == ["Saturday football"])
        #expect(try await hero.labels(keys) == Array(repeating: "Saturday football", count: 10))
        #expect(try await hero.reader.searchPlaces("pitch", limit: 3).allSatisfy { $0.kind != .saved }, "the old name is gone from the place index")

        try await hero.writer.setRadius(id, 100)
        await hero.indexer.settled()
        #expect(try await hero.reader.savedPlaces().first?.radius == 100)
        #expect(try await hero.database.read { db in try Double.fetchOne(db, sql: "SELECT radius_m FROM place WHERE key = ?", arguments: [PlaceKey.saved(id)]) } == 100)

        try await hero.writer.deletePlace(id)
        await hero.indexer.settled()
        #expect(try await hero.reader.savedPlaces().isEmpty)
        #expect(try await hero.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM place WHERE kind = 6") } == 0)
        #expect(try await hero.labels(keys) == Array(repeating: "Al-Nakheel Park", count: 10), "labels go back to the park")
    }

    @Test func namesMustBeUniqueAndNotEmpty() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let writer = UserDataWriter(database: database, clock: FixedClock(Fixture.now))
        let id = try await writer.savePlace(name: "My pitch", center: Fixture.nakheel, radius: 250, isHome: false)
        await #expect(throws: SavedPlaceError.nameTaken) { try await writer.savePlace(name: "my PITCH", center: Fixture.athens, radius: 100, isHome: false) }
        await #expect(throws: SavedPlaceError.emptyName) { try await writer.savePlace(name: "   ", center: Fixture.athens, radius: 100, isHome: false) }
        let other = try await writer.savePlace(name: "Gym", center: Fixture.athens, radius: 100, isHome: false)
        await #expect(throws: SavedPlaceError.nameTaken) { try await writer.renamePlace(other, to: "My Pitch") }
        try await writer.renamePlace(id, to: "my pitch")
        await #expect(throws: SavedPlaceError.notFound) { try await writer.setRadius(999, 100) }
        #expect(try await IndexReader(database: database).savedPlaces().map(\.name) == ["Gym", "my pitch"])
    }

    @Test func rebuildKeepsSavedPlacesAndTheirLabels() async throws {
        let hero = try await Hero()
        let keys = try await hero.nakheelKeys()
        let id = try await hero.writer.savePlace(name: "My pitch", center: try await hero.nakheelCenter(), radius: 250, isHome: false)
        await hero.indexer.settled()
        await Fixture.sync(hero.indexer, .rebuild)
        #expect(try await hero.reader.savedPlaces().map(\.id) == [id])
        #expect(try await hero.labels(keys) == Array(repeating: "My pitch", count: 10), "the rebuilt moments are labelled with it again")
    }

    // MARK: Home

    @Test func homeCanBeASavedPlaceANightPlaceTheEstimateOrNone() async throws {
        let hero = try await Hero()
        let estimated = try #require(try await hero.reader.homeBase(year: nil))
        #expect(estimated.source == .estimated)
        #expect(try await hero.reader.homeSetting() == .estimated(estimated))
        let tripCount = try await hero.reader.trips().count
        #expect(tripCount == 6)

        let candidates = try await hero.reader.homeCandidates(limit: 5)
        #expect(candidates.first?.isEstimate == true && candidates.first?.tile == estimated.tile, "the estimate first: most nights")
        #expect(candidates.count(where: \.isEstimate) == 1)
        #expect(candidates.first?.nights ?? 0 >= 100)
        #expect(candidates.map(\.nights) == candidates.map(\.nights).sorted(by: >))

        // A night place picked as home: saved as "Home", every year's home.
        let elsewhere = try #require(candidates.dropFirst().first)
        try await hero.writer.setHome(.point(elsewhere.center))
        await hero.indexer.settled()
        guard case .saved(let picked) = try await hero.reader.homeSetting() else { Issue.record("not a saved home"); return }
        #expect(picked.name == "Home" && picked.isHome && picked.radius == 150)
        #expect(try await hero.reader.homeBase(year: nil)?.source == .user)
        #expect(try await hero.reader.homeBase(year: nil)?.center == elsewhere.center)

        // A saved place set as home replaces the picked one.
        let pitch = try await hero.writer.savePlace(name: "My pitch", center: try await hero.nakheelCenter(), radius: 250, isHome: true)
        await hero.indexer.settled()
        #expect(try await hero.reader.savedPlaces().map(\.name) == ["My pitch"], "the picked Home is gone")
        guard case .saved(let home) = try await hero.reader.homeSetting() else { Issue.record("not a saved home"); return }
        #expect(home.id == pitch)

        // No home: no home bases, so no trips; then back to the estimate.
        try await hero.writer.setHome(.noHome)
        await hero.indexer.settled()
        #expect(try await hero.reader.homeSetting() == .noHome)
        #expect(try await hero.reader.homeBase(year: nil) == nil)
        #expect(try await hero.reader.trips().isEmpty)
        #expect(try await hero.reader.savedPlaces().first?.isHome == false, "the place stays, no longer home")

        await Fixture.sync(hero.indexer, .rebuild)
        #expect(try await hero.reader.homeSetting() == .noHome, "Rebuild keeps the choice")

        try await hero.writer.setHome(.estimated)
        await hero.indexer.settled()
        #expect(try await hero.reader.homeBase(year: nil) == estimated)
        #expect(try await hero.reader.trips().count == tripCount)
    }

    @Test func deletingTheHomePlaceGoesBackToTheEstimate() async throws {
        let hero = try await Hero()
        let estimated = try await hero.reader.homeBase(year: nil)
        let id = try await hero.writer.savePlace(name: "Flat", center: Fixture.athens, radius: 100, isHome: true)
        await hero.indexer.settled()
        #expect(try await hero.reader.homeBase(year: nil)?.source == .user)
        try await hero.writer.deletePlace(id)
        await hero.indexer.settled()
        #expect(try await hero.reader.homeBase(year: nil) == estimated)
    }
}
