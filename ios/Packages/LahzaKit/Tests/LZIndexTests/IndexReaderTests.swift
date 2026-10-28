import Foundation
import GRDB
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex

/// The read queries: the summary, moment pages, moment detail, trips, home bases, local identifiers and the
/// inspector. Structure rows are inserted directly here; the structure pass fills them in the app.
@Suite struct IndexReaderTests {
    /// Six photos over two days (2 and 3 Jan 2025, Riyadh), three moments, one trip, a home base and places.
    private func structured() async throws -> (IndexDatabase, IndexReader) {
        let base: Int64 = 1_735_808_400                                              // 2025-01-02 09:00 UTC, 12:00 in Riyadh
        let assets = [
            Fixture.photo("p1", base, at: Fixture.nakheel), Fixture.photo("p2", base + 600, favorite: true),
            Fixture.photo("p3", base + 7_200, at: Fixture.nakheel, kind: .video),
            Fixture.photo("p4", base + 86_400, at: Fixture.athens), Fixture.photo("p5", base + 86_700, at: Fixture.athens),
            Fixture.photo("p6", base + 90_000, at: Fixture.athens),
        ]
        let database = try IndexDatabase.open(.inMemory)
        await Fixture.sync(Fixture.indexer(database, FakeLibraryReader(.explicit(assets))))
        try await database.write { db in
            let ids = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT local_id, id FROM asset").map { ($0["local_id"] as String, $0["id"] as Int64) })
            let day2 = LocalTime.day(year: 2025, month: 1, day: 2), day3 = day2 + 1
            try db.execute(sql: """
                INSERT INTO place (id, kind, key, name, country_code, photo_count, source) VALUES
                  (1, 1, 'cc:SA', 'Saudi Arabia', 'SA', 3, 1), (2, 3, 'gn:108410', 'Riyadh', 'SA', 3, 1), (3, 5, 'mk:nakheel', 'Al-Nakheel Park', 'SA', 2, 2),
                  (4, 1, 'cc:GR', 'Greece', 'GR', 3, 1), (5, 3, 'gn:264371', 'Athens', 'GR', 3, 1);
                INSERT INTO cell (cell, lat, lon, photo_count, day_count, poi_status) VALUES ('a', 0, 0, 1, 1, 1), ('b', 0, 0, 1, 1, 1), ('c', 0, 0, 1, 1, 6);
                INSERT INTO trip (id, start_day, end_day, label, country_place, abroad, moment_count, item_count, video_count, max_km, cover_asset)
                  VALUES (7, \(day3), \(day3 + 1), 'Greece', 4, 1, 1, 3, 0, 2400, \(ids["p5"]!));
                INSERT INTO home_base (year, lat, lon, tile, tz, country_code, nights, source) VALUES
                  (2024, 24.748, 46.633, '\(GeoHash.encode(Fixture.nakheel, precision: 6))', (SELECT id FROM zone WHERE name = 'Asia/Riyadh'), 'SA', 30, 1),
                  (2025, 24.748, 46.633, '\(GeoHash.encode(Fixture.nakheel, precision: 6))', (SELECT id FROM zone WHERE name = 'Asia/Riyadh'), 'SA', 40, 0);
                UPDATE asset SET city_place = 2, country_place = 1 WHERE local_id IN ('p1', 'p3');
                UPDATE asset SET city_place = 5, country_place = 4, trip_id = 7 WHERE local_id IN ('p4', 'p5', 'p6');
                UPDATE asset SET place_src = 2 WHERE local_id = 'p2';
                """)
            func moment(_ id: Int64, day: Int32, members: [String], label: Int64?, city: Int64?, country: Int64?, trip: Int64?) throws {
                let utcs = try members.map { try Int64.fetchOne(db, sql: "SELECT created_utc FROM asset WHERE local_id = ?", arguments: [$0])! }
                try db.execute(sql: """
                    INSERT INTO moment (id, day, start_utc, end_utc, start_wall, end_wall, tz, first_asset, item_count, photo_count, video_count,
                      located_count, borrowed_count, label_place, city_place, country_place, trip_id, cover_asset)
                    VALUES (?, ?, ?, ?, ?, ?, (SELECT id FROM zone WHERE name = 'Asia/Riyadh'), ?, ?, ?, 0, ?, 0, ?, ?, ?, ?, ?)
                    """, arguments: [id, day, utcs.first, utcs.last, utcs.first! + 10_800, utcs.last! + 10_800, ids[members[0]], members.count, members.count,
                                     members.count, label, city, country, trip, ids[members[0]]])
                for member in members { try db.execute(sql: "UPDATE asset SET moment_id = ? WHERE local_id = ?", arguments: [id, member]) }
            }
            try moment(1, day: day2, members: ["p1", "p2"], label: 3, city: 2, country: 1, trip: nil)
            try moment(2, day: day2, members: ["p3"], label: 2, city: 2, country: 1, trip: nil)
            try moment(3, day: day3, members: ["p4", "p5", "p6"], label: 5, city: 5, country: 4, trip: 7)
        }
        return (database, IndexReader(database: database))
    }

    @Test func theSummaryCountsTheLibraryAndItsStructure() async throws {
        let (_, reader) = try await structured()
        let summary = try await reader.summary()
        #expect(summary == LibrarySummary(assets: 6, photos: 5, videos: 1, located: 5, moments: 3, trips: 1, countries: 2,
                                          firstYear: 2025, lastYear: 2025, homeCityName: "Riyadh"))
    }

    @Test func momentsPageNewestFirstByKey() async throws {
        let (_, reader) = try await structured()
        let first = try await reader.moments(after: nil, limit: 2)
        #expect(first.map(\.id) == [3, 2])
        #expect(first[0].label == "Athens")
        #expect(first[0].countryCode == "GR")
        #expect(first[0].tripID == 7)
        #expect(first[0].timeZone == "Asia/Riyadh")
        let next = try await reader.moments(after: try #require(first.last?.key), limit: 2)
        #expect(next.map(\.id) == [1])
        #expect(next[0].label == "Al-Nakheel Park")
        #expect(next[0].coverLocalID == "p1")
        #expect(try await reader.moments(after: nil, limit: 10, filter: MomentFilter(tripID: 7)).map(\.id) == [3])
        #expect(try await reader.moments(after: nil, limit: 10, filter: MomentFilter(year: 2024)).isEmpty)
        #expect(try await reader.moments(after: nil, limit: 10, filter: MomentFilter(year: 2025)).count == 3)
        #expect(try await reader.momentRows(ids: [1, 3, 99]).map(\.id) == [3, 1])
    }

    @Test func aMomentListsItsItemsInTimeOrder() async throws {
        let (_, reader) = try await structured()
        let key = try #require(try await reader.moments(after: nil, limit: 3).last?.key)
        let detail = try #require(try await reader.moment(key))
        #expect(detail.moment.id == 1)
        #expect(detail.members.map(\.localID) == ["p1", "p2"])
        #expect(detail.members.map(\.isFavorite) == [false, true])
        #expect(detail.members.map(\.hasBorrowedLocation) == [false, true])
        #expect(try await reader.moment(MomentKey(day: key.day, startUTC: key.startUTC + 1)) == nil)
    }

    @Test func tripsAndHomeBases() async throws {
        let (_, reader) = try await structured()
        let trips = try await reader.trips()
        #expect(trips.count == 1)
        #expect(trips.first?.label == "Greece")
        #expect(trips.first?.countryCode == "GR")
        #expect(trips.first?.abroad == true)
        #expect(trips.first?.coverLocalID == "p5")
        #expect(try await reader.homeBase(year: nil)?.year == 2025)
        let inherited = try #require(try await reader.homeBase(year: 2024))
        #expect(inherited.source == .inherited)
        #expect(inherited.timeZone == "Asia/Riyadh")
        #expect(try await reader.homeBase(year: 2019) == nil)
    }

    @Test func rowsCarryTheirThumbnailsAndTripsTheirPlacesAndMosaic() async throws {
        let (database, reader) = try await structured()
        try await database.write { db in
            try db.execute(sql: "UPDATE moment SET cover_asset = (SELECT id FROM asset WHERE local_id = 'p6') WHERE id = 3")
            try db.execute(sql: """
                INSERT INTO place (id, kind, key, name, country_code, photo_count, source) VALUES (6, 4, 'al:GR:oia', 'Oia', 'GR', 1, 2);
                INSERT INTO moment (id, day, start_utc, end_utc, start_wall, end_wall, first_asset, item_count, photo_count, video_count,
                  located_count, borrowed_count, label_place, country_place, trip_id, cover_asset)
                  SELECT 4, day + 1, created_utc + 86400, created_utc + 86400, 0, 0, id, 1, 1, 0, 1, 0, 6, 4, 7, id FROM asset WHERE local_id = 'p5';
                INSERT INTO moment (id, day, start_utc, end_utc, start_wall, end_wall, first_asset, item_count, photo_count, video_count,
                  located_count, borrowed_count, label_place, country_place, trip_id, cover_asset)
                  SELECT 5, day + 1, created_utc + 90000, created_utc + 90000, 0, 0, id, 1, 1, 0, 1, 0, 4, 4, 7, id FROM asset WHERE local_id = 'p4';
                """)
        }
        let rows = try await reader.moments(after: nil, limit: 10)
        #expect(rows.first { $0.id == 3 }?.thumbnailLocalIDs == ["p6", "p4", "p5"], "the cover first, then time order")
        #expect(rows.first { $0.id == 1 }?.thumbnailLocalIDs == ["p1", "p2"])
        #expect(try await reader.momentRows(ids: [2]).first?.thumbnailLocalIDs == ["p3"])
        let key = try #require(rows.first { $0.id == 3 }?.key)
        #expect(try await reader.moment(key)?.moment.thumbnailLocalIDs == ["p6", "p4", "p5"])

        let trip = try #require(try await reader.trips().first)
        #expect(trip.places == ["Athens", "Oia"], "cities, then towns, in visiting order; the country label and the trip's own label are left out")
        #expect(trip.thumbnailLocalIDs.first == "p5", "the trip's cover leads the mosaic")
        #expect(Set(trip.thumbnailLocalIDs) == ["p5", "p6", "p4"])
        #expect(trip.thumbnailLocalIDs.count == 3)
    }

    @Test func localIdentifiersForRowIDs() async throws {
        let (database, reader) = try await structured()
        let ids = try await database.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM asset ORDER BY local_id") }
        let identifiers = try await reader.localIdentifiers(for: ids + [9_999])
        #expect(identifiers.count == 6)
        #expect(identifiers[ids[0]] == "p1")
    }

    @Test func theInspectorShowsStateAndAggregatesOnly() async throws {
        let (_, reader) = try await structured()
        let data = try await reader.inspector()
        #expect(data.scanPhase == "idle")
        #expect(data.hasChangeToken)
        #expect(data.firstBuildDone)
        #expect(data.scanGeneration == 1)
        #expect(data.accessScope == "full")
        #expect(data.structureVersion == Int64(IndexSchema.structureVersion))
        #expect(data.deviceTimeZone == "Asia/Riyadh")
        #expect(data.tables.first { $0.name == "asset" }?.rows == 6)
        #expect(data.tables.map(\.name) == IndexSchema.tables)
        #expect(data.placeNameStatus == [1: 2, 6: 1])
        #expect(data.homeBases.map(\.year) == [2024, 2025])
        #expect(data.trips.map(\.label) == ["Greece"])
        #expect(data.topPlaces.first?.photos == 3)
    }
}
