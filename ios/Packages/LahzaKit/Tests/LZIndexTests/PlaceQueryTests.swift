import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex

/// Search's place queries and writes: FTS5 names with match kinds and the typo pass, places by kind or key, remembered
/// picks, the Apple Maps search cache and its places, counts around a point, and what Rebuild keeps.
@Suite struct PlaceQueryTests {
    static let dammam = Coordinate(latitude: 26.43, longitude: 50.10)
    static let salamRiyadh = Coordinate(latitude: 24.6236, longitude: 46.7070)
    static let salamDubai = Coordinate(latitude: 25.2310, longitude: 55.3000)

    /// An index holding a few places with photo counts set directly.
    private func places() async throws -> (IndexDatabase, IndexReader) {
        let database = try IndexDatabase.open(.inMemory)
        try await database.write { db in
            var rows = PlaceRows(db)
            func add(_ spec: PlaceSpec, photos: Int) throws {
                let id = try rows.id(spec)
                try db.execute(sql: "UPDATE place SET photo_count = ? WHERE id = ?", arguments: [photos, id])
            }
            try add(PlaceSpec(poi: MapPlace(appleID: "nakheel", name: "Al-Nakheel Park", category: .park, coordinate: Fixture.nakheel)), photos: 85)
            try add(PlaceSpec(mapResult: MapPlace(appleID: "dammam", name: "Al Nakheel Park", category: .park, coordinate: Self.dammam)), photos: 0)
            try add(PlaceSpec(poi: MapPlace(appleID: "salam", name: "Salam Park", category: .park, coordinate: Self.salamRiyadh)), photos: 10)
            try add(PlaceSpec(poi: MapPlace(appleID: "salam-dubai", name: "Salam Park", category: .park, coordinate: Self.salamDubai)), photos: 8)
            try add(PlaceSpec(key: "gn:110312", kind: .locality, name: "Ad Dir‘īyah", names: ["Ad Dir‘īyah", "Ad Diriyah", "Diriyah"], source: .gazetteer),
                    photos: 12)
            try add(PlaceSpec(country: "AE"), photos: 57)
            try add(PlaceSpec(country: "FR"), photos: 0)
        }
        return (database, IndexReader(database: database))
    }

    @Test func namesMatchExactlyByWordsOrByPrefix() async throws {
        let (_, reader) = try await places()
        let park = try await reader.searchPlaces("al-nakheel park", limit: 5)
        #expect(park.map(\.key) == ["mk:nakheel", "mk:dammam"], "both exact; the one with photos first")
        #expect(park.allSatisfy { $0.match == .exact })
        #expect(park.first?.kind == .poi && park.first?.category == .park && park.first?.radius == 400 && park.first?.photoCount == 85)
        #expect(park.last?.kind == .mapResult && park.last?.isFromAppleMaps == true)

        let word = try await reader.searchPlaces("Nakheel", limit: 5)
        #expect(word.map(\.match) == [.allTokens, .allTokens])
        #expect(try await reader.searchPlaces("nakheel pa", limit: 5).first?.match == .prefix)
        #expect(try await reader.searchPlaces("Diriyah", limit: 5).map { [$0.key, $0.matchedName] } == [["gn:110312", "diriyah"]])
        #expect(try await reader.searchPlaces("ad-Dir'iyah", limit: 5).first?.match == .exact, "Arabic article and apostrophe folded")
        #expect(try await reader.searchPlaces("Salam Park", limit: 5).map(\.photoCount) == [10, 8])
        #expect(try await reader.searchPlaces("Salam Park", limit: 1).count == 1)
        #expect(try await reader.searchPlaces("uae", limit: 5).map(\.key) == ["cc:AE"], "country synonyms are names too")
        #expect(try await reader.searchPlaces("", limit: 5).isEmpty)
    }

    @Test func theTypoPassLooksOnlyAtPlacesWithPhotos() async throws {
        let (_, reader) = try await places()
        let typo = try await reader.searchPlaces("nakhel prk", limit: 5)
        #expect(typo.map(\.key) == ["mk:nakheel"], "the Dammam park has no photos")
        #expect(typo.first?.match == .typo && typo.first?.matchedName == "al nakheel park")
        #expect(try await reader.searchPlaces("salm parc", limit: 5).map(\.key) == ["mk:salam", "mk:salam-dubai"])
        #expect(try await reader.searchPlaces("al nakhel", limit: 5).map(\.key) == ["mk:nakheel"], "a short word must be equal")
        #expect(try await reader.searchPlaces("el nakhel", limit: 5).isEmpty)
        #expect(try await reader.searchPlaces("xyz", limit: 5).isEmpty)
        #expect(PlaceQueries.withinOneEdit(Array("park".unicodeScalars), Array("prk".unicodeScalars)))
        #expect(PlaceQueries.withinOneEdit(Array("nakhel".unicodeScalars), Array("nakheel".unicodeScalars)))
        #expect(PlaceQueries.withinOneEdit(Array("salm".unicodeScalars), Array("salam".unicodeScalars)))
        #expect(!PlaceQueries.withinOneEdit(Array("prak".unicodeScalars), Array("park".unicodeScalars)), "a swap is two edits")
    }

    @Test func placesByKindAndByKey() async throws {
        let (_, reader) = try await places()
        #expect(try await reader.places(kinds: [.poi], minPhotos: 1, limit: 10).map(\.photoCount) == [85, 10, 8])
        #expect(try await reader.places(kinds: [.poi, .mapResult], minPhotos: 0, limit: 10).count == 4)
        #expect(try await reader.places(kinds: [.country], minPhotos: 1, limit: 10).map(\.key) == ["cc:AE"])
        #expect(try await reader.places(kinds: [], minPhotos: 0, limit: 10).isEmpty)
        let found = try await reader.places(keys: ["cc:FR", "gn:110312", "nope"])
        #expect(Set(found.keys) == ["cc:FR", "gn:110312"])
        #expect(found["cc:FR"]?.name == "France" && found["cc:FR"]?.center == nil)
        #expect(try await reader.ownPlaceNames().isSuperset(of: ["al nakheel park", "nakheel park", "diriyah", "uae"]))
        #expect(try await !reader.ownPlaceNames().contains("france"), "no photos in France")
    }

    @Test func rememberedPicksAreFoldedAndReplaced() async throws {
        let (database, reader) = try await places()
        let clock = FixedClock(Fixture.now)
        let writer = UserDataWriter(database: database, clock: clock)
        #expect(try await reader.placeChoice(for: "salam park") == nil)
        try await writer.rememberChoice(phrase: "Salam Park", placeKey: "mk:salam-dubai", radius: nil)
        #expect(try await reader.placeChoice(for: "salam park") == PlaceChoiceRow(phrase: "salam park", placeKey: "mk:salam-dubai", radius: nil,
                                                                                    updated: Fixture.now))
        await clock.advance(by: .seconds(60))
        try await writer.rememberChoice(phrase: "salam-park", placeKey: "mk:salam", radius: 1_000)
        let choice = try await reader.placeChoice(for: "SALAM PARK")
        #expect(choice?.placeKey == "mk:salam" && choice?.radius == 1_000 && choice?.updated == Fixture.now.addingTimeInterval(60))
        #expect(try await Fixture.count(database, "place_choice") == 1)
    }

    @Test func appleMapsAnswersAreCachedAndJoinTheIndex() async throws {
        let (database, reader) = try await places()
        let clock = FixedClock(Fixture.now)
        let writer = UserDataWriter(database: database, clock: clock)
        let sufra = MapPlace(appleID: "sufra", name: "Sufra Grill", category: .restaurant, coordinate: Coordinate(latitude: 24.7155, longitude: 46.6790),
                             cityName: "Riyadh", countryCode: "SA")
        let santorini = MapPlace(name: "Santorini", category: .physicalFeature, coordinate: Coordinate(latitude: 36.4072, longitude: 25.4567),
                                 kind: .physicalFeature, boundingRadius: 10_000, countryCode: "GR")
        let renamed = MapPlace(appleID: "nakheel", name: "Al Nakheel Park", category: .park, coordinate: Fixture.nakheel)
        try await database.write { db in try Meta.set(db, .structureDue, nil) }
        try await writer.rememberMapResults(key: "sufra grill|-", results: [sufra, santorini, renamed])

        #expect(try await reader.cachedMapSearch(key: "sufra grill|-", maxAge: .seconds(30 * 86_400), now: Fixture.now) == [sufra, santorini, renamed])
        #expect(try await reader.cachedMapSearch(key: "sufra grill|-", maxAge: .seconds(30 * 86_400), now: Fixture.now.addingTimeInterval(29 * 86_400)) != nil)
        #expect(try await reader.cachedMapSearch(key: "sufra grill|-", maxAge: .seconds(30 * 86_400), now: Fixture.now.addingTimeInterval(31 * 86_400)) == nil)
        #expect(try await reader.cachedMapSearch(key: "other|-", maxAge: .seconds(30 * 86_400), now: Fixture.now) == nil)

        let rows = try await reader.places(keys: ["mk:sufra", PlaceKey.mapPlace(santorini), "mk:nakheel"])
        #expect(rows["mk:sufra"]?.kind == .mapResult && rows["mk:sufra"]?.radius == 75 && rows["mk:sufra"]?.isFromAppleMaps == true)
        #expect(rows[PlaceKey.mapPlace(santorini)]?.radius == 10_000 && PlaceKey.mapPlace(santorini) == "mkn:santorini@36.4072,25.4567")
        #expect(rows["mk:nakheel"]?.kind == .poi && rows["mk:nakheel"]?.name == "Al-Nakheel Park", "a point of interest is left to place naming")
        #expect(rows["mk:nakheel"]?.photoCount == 85)
        #expect(try await reader.searchPlaces("sufra grill", limit: 3).first?.key == "mk:sufra", "found by name from now on")
        #expect(try await database.read { db in try Meta.int(db, .structureDue) } == 1, "place counts read place rows")

        // An empty answer is remembered, and marks nothing.
        try await database.write { db in try Meta.set(db, .structureDue, nil) }
        try await writer.rememberMapResults(key: "narnia|-", results: [])
        #expect(try await reader.cachedMapSearch(key: "narnia|-", maxAge: .seconds(86_400), now: Fixture.now) == [])
        #expect(try await database.read { db in try Meta.int(db, .structureDue) } == nil)

        // Place naming later finds the restaurant's neighbour as a point of interest: a search result becomes one.
        try await database.write { db in
            var rows = PlaceRows(db)
            _ = try rows.id(PlaceSpec(poi: sufra), refresh: true)
        }
        #expect(try await reader.places(keys: ["mk:sufra"])["mk:sufra"]?.kind == .poi)
    }

    @Test func countsAroundAPointUseEffectivePositions() async throws {
        let base: Int64 = 1_735_808_400
        let away = Coordinate(latitude: Fixture.nakheel.latitude + 0.009, longitude: Fixture.nakheel.longitude)   // 1 km north
        let assets = [
            Fixture.photo("a", base, at: Fixture.nakheel), Fixture.photo("b", base + 60, at: Fixture.nakheel),
            Fixture.photo("c", base + 120, at: Coordinate(latitude: Fixture.nakheel.latitude + 0.001, longitude: Fixture.nakheel.longitude)),
            Fixture.photo("d", base + 300),                                                       // borrows the moment's position
            Fixture.photo("e", base + 600, at: away),
        ]
        let database = try IndexDatabase.open(.inMemory)
        await Fixture.sync(Fixture.structured(database, FakeLibraryReader(.explicit(assets))))
        let reader = IndexReader(database: database)
        #expect(try await reader.countWithin(Fixture.nakheel, radius: 400) == 4, "three with GPS and one borrowing")
        let distances = try await reader.ownDistances(from: Fixture.nakheel, within: 400)
        #expect(distances.count == 3 && distances.allSatisfy { $0 < 120 })
        #expect(try await reader.countWithin(Fixture.nakheel, radius: 1_200) == 5)
        #expect(try await reader.countWithin(Coordinate(latitude: 0, longitude: 0), radius: 1_000) == 0)
        #expect(try await reader.indexVersion() > 0)
        #expect(try await reader.savedPlaces().isEmpty)
    }

    @Test func rebuildKeepsSearchResultsTheCacheAndPicks() async throws {
        let assets = Fixture.library(30)
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.structured(database, FakeLibraryReader(.explicit(assets)))
        await Fixture.sync(indexer)
        let writer = UserDataWriter(database: database, clock: FixedClock(Fixture.now))
        let found = MapPlace(appleID: "found", name: "Sufra Grill", category: .restaurant, coordinate: Coordinate(latitude: 24.7155, longitude: 46.6790))
        try await writer.rememberMapResults(key: "sufra grill|-", results: [found])
        try await writer.rememberChoice(phrase: "sufra", placeKey: "mk:found", radius: nil)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO saved_place (id, name, name_folded, lat, lon, radius_m, is_home, created_utc, updated_utc)
                VALUES (1, 'My pitch', 'my pitch', 24.759, 46.644, 250, 0, 0, 0)
                """)
        }
        await Fixture.sync(indexer, .rebuild)
        let reader = IndexReader(database: database)
        #expect(try await reader.places(keys: ["mk:found"])["mk:found"]?.kind == .mapResult)
        #expect(try await reader.cachedMapSearch(key: "sufra grill|-", maxAge: .seconds(86_400), now: Fixture.now) == [found])
        #expect(try await reader.placeChoice(for: "sufra")?.placeKey == "mk:found")
        #expect(try await reader.savedPlaces().map(\.name) == ["My pitch"])
        #expect(try await Fixture.count(database, "asset") == assets.count, "and the library is read again")
    }
}
