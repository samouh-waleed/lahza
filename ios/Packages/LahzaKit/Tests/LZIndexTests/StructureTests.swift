import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Testing
@testable import LZIndex

/// The structure pass (P0b): zones for photos without GPS, places, moments and their labels, home bases, trips,
/// cells and place counts, on the hero seed and on small libraries built for one rule each.
@Suite struct StructureTests {
    static let home = SeedPlace.home.coordinate
    static let athens = TimeZone(identifier: "Europe/Athens")!
    static let london = TimeZone(identifier: "Europe/London")!
    static let oia = SeedPlace.oia.coordinate
    static let atTuraif = SeedPlace.atTuraif.coordinate

    /// UTC seconds of a local wall time in `zone`.
    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone = Fixture.riyadh) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return Int64(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!.timeIntervalSince1970)
    }

    /// A photo `metres` east of `place`.
    static func east(of place: Coordinate, _ metres: Double) -> Coordinate {
        Coordinate(latitude: place.latitude, longitude: place.longitude + metres / (111_320 * cos(place.latitude * .pi / 180)))
    }

    /// Photos at home at 21:00 on `count` days, every 5 days from `start` (a home base for that year).
    static func homeNights(_ year: Int, from start: (Int, Int) = (1, 1), count: Int = 12, prefix: String = "home") -> [LibraryAsset] {
        let first = LocalTime.day(year: year, month: start.0, day: start.1)
        return (0..<count).map { index in
            let date = LocalTime.civil(day: first + Int32(index * 5))
            return Fixture.photo("\(prefix)-\(year)-\(index)", utc(date.year, date.month, date.day, 21), at: home)
        }
    }

    private func build(_ assets: [LibraryAsset], zone: TimeZone = Fixture.riyadh) async throws -> (IndexDatabase, LibraryIndexer, FakeLibraryReader) {
        let reader = FakeLibraryReader(.explicit(assets))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.structured(database, reader, zone: { zone })
        await Fixture.sync(indexer)
        return (database, indexer, reader)
    }

    private struct Derived: Sendable, Hashable {
        var zone: String?
        var zoneSource: Int
        var day: Int32?
        var placeSource: Int
        var effective: Coordinate?
        var city: String?
        var locality: String?
        var country: String?
        var moment: Int64?
        var momentLabel: String?
    }

    private func derived(_ database: IndexDatabase) async throws -> [String: Derived] {
        try await database.read { db in
            var rows: [String: Derived] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT a.local_id, z.name AS zone, a.tz_src, a.day, a.place_src, a.eff_lat, a.eff_lon, city.name AS city, locality.name AS locality,
                       country.country_code AS country, a.moment_id, label.name AS label
                FROM asset a LEFT JOIN zone z ON z.id = a.tz LEFT JOIN place city ON city.id = a.city_place LEFT JOIN place locality ON locality.id = a.locality_place
                LEFT JOIN place country ON country.id = a.country_place LEFT JOIN moment m ON m.id = a.moment_id LEFT JOIN place label ON label.id = m.label_place
                """) {
                let effective = (row["eff_lat"] as Double?).flatMap { lat in (row["eff_lon"] as Double?).map { Coordinate(latitude: lat, longitude: $0) } }
                rows[row["local_id"]] = Derived(zone: row["zone"], zoneSource: row["tz_src"], day: row["day"], placeSource: row["place_src"], effective: effective,
                                                city: row["city"], locality: row["locality"], country: row["country"], moment: row["moment_id"],
                                                momentLabel: row["label"])
            }
            return rows
        }
    }

    // MARK: The hero seed

    @Test func theHeroSeedHasItsSixTripsAndAHomeEveryYear() async throws {
        let (database, _, _) = try await build(SeedScenario.hero.libraryAssets)
        let reader = IndexReader(database: database)
        let trips = try await reader.trips()
        let expected = SeedScenario.hero.trips.reversed()
        #expect(trips.map(\.startDay) == expected.map(\.firstDay))
        #expect(trips.map(\.endDay) == expected.map(\.lastDay))
        #expect(trips.map(\.label) == expected.map(\.name))
        #expect(trips.map(\.countryCode) == expected.map(\.countryCode))
        #expect(trips.map(\.abroad) == expected.map { $0.countryCode != "SA" })
        let greece = try #require(trips.first { $0.label == "Greece" })
        #expect(greece.itemCount == SeedScenario.hero.items(.greece).count)

        let homes = try await IndexQueries.homes(database)
        #expect(homes.map(\.year) == Array(2021...2026))
        #expect(homes.first?.source == .inherited, "2021 has no ten nights anywhere: it inherits 2022's")
        for home in homes {
            #expect(home.center.distance(to: Self.home) < 50, "\(home.year)")
            #expect(home.timeZone == "Asia/Riyadh")
            #expect(home.countryCode == "SA")
        }
        #expect(try await Fixture.dirtyDays(database).isEmpty)
    }

    @Test func photosWithoutGPSBorrowAsTheScenarioIntends() async throws {
        let (database, _, _) = try await build(SeedScenario.hero.libraryAssets)
        let rows = try await derived(database)
        for item in SeedScenario.hero.items where item.coordinate == nil && item.utc != nil {
            let row = try #require(rows[item.id])
            #expect(row.day == item.momentDay, "\(item.id) \(item.tag): local day in its own zone")
            #expect(row.zone == item.zone, "\(item.id) \(item.tag)")
            switch item.borrowing {
            case .moment:
                #expect(row.placeSource == PlaceSource.momentNear.rawValue, "\(item.id): within 10 min of a located photo of its moment")
                #expect(row.city == "Riyadh")
            case .beyondMoment, .sameDay:
                #expect(row.zoneSource == ZoneSource.borrowed.rawValue, "\(item.id): a located photo within 12 h")
                #expect(row.placeSource == PlaceSource.none.rawValue, "\(item.id): too far in time to borrow a position")
            case .noZone:
                #expect(row.zoneSource == ZoneSource.home.rawValue, "\(item.id): no located photo within 12 h, so the home zone")
                #expect(row.placeSource == PlaceSource.none.rawValue)
            case .none:
                break
            }
        }
    }

    @Test func locatedPhotosArePlacedByTheGazetteer() async throws {
        let (database, _, _) = try await build(SeedScenario.hero.libraryAssets)
        let rows = try await derived(database)
        func places(_ tag: SeedScenario.Tag, title: String? = nil) -> Set<[String?]> {
            Set(SeedScenario.hero.items(tag).filter { $0.coordinate != nil && (title == nil || $0.title == title) }.compactMap { rows[$0.id] }
                .map { [$0.city, $0.locality, $0.country] })
        }
        #expect(places(.nakheel) == [["Riyadh", nil, "SA"]])
        #expect(places(.diriyah) == [["Riyadh", "Ad Dir‘īyah", "SA"]])
        #expect(places(.london).allSatisfy { $0[0] == "London" && $0[2] == "GB" })
        #expect(places(.sydney).allSatisfy { $0[0] == "Sydney" && $0[2] == "AU" })
        #expect(places(.greece, title: "Oia") == [[nil, nil, "GR"]], "no gazetteer city on Santorini until Apple Maps names it")
        #expect(places(.dubai2).allSatisfy { $0[0] == "Dubai" && $0[2] == "AE" })
        let metro = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset a JOIN place m ON m.id = a.metro_place WHERE m.name = 'Riyadh' AND a.local_id IN ('\(SeedScenario.hero.items(.nakheel).filter(\.isLocated).map(\.id).joined(separator: "','"))')")
        }
        #expect(metro == SeedScenario.hero.items(.nakheel).filter(\.isLocated).count)
    }

    @Test func appleMapsNamesRelabelMomentsAndKeepTheirIDs() async throws {
        let (database, indexer, _) = try await build(SeedScenario.hero.libraryAssets)
        let reader = IndexReader(database: database)
        func allMoments() async throws -> [MomentRow] {
            var rows: [MomentRow] = [], key: MomentKey?
            while true {
                let page = try await reader.moments(after: key, limit: 100)
                guard let last = page.last else { return rows }
                rows += page
                key = last.key
            }
        }
        let before = try await allMoments()
        let lastPark = try #require(before.first { $0.key.day == LocalTime.day(year: 2026, month: 8, day: 22) && $0.itemCount == 8 })
        #expect(lastPark.label == "Riyadh", "before Apple Maps: the city")
        #expect(lastPark.cell.map { GeoHash.center($0).distance(to: Fixture.nakheel) < 250 } == true)
        #expect(lastPark.photoCount == 8)

        await Fixture.placeNames(database, indexer, maps: SeedMaps.client()).run()
        await indexer.settled()
        let after = try await allMoments()
        #expect(Dictionary(uniqueKeysWithValues: after.map { ($0.key, $0.id) }) == Dictionary(uniqueKeysWithValues: before.map { ($0.key, $0.id) }),
                "only labels changed, so every moment keeps its id")
        let parks = after.filter { $0.label == "Al-Nakheel Park" }
        #expect(parks.count == 10)
        #expect(parks.reduce(0) { $0 + $1.itemCount } == SeedScenario.hero.items(.nakheel).count)
        #expect(after.contains { $0.label == "Oia" })
        #expect(after.contains { $0.label == "Mykonos" })
        let park = try await database.read { db in try Row.fetchOne(db, sql: "SELECT kind, photo_count FROM place WHERE name = 'Al-Nakheel Park'").map { [$0["kind"] as Int, $0["photo_count"] as Int] } }
        #expect(park == [PlaceKind.poi.rawValue, SeedScenario.hero.items(.nakheel).filter(\.isLocated).count])
        #expect(try await reader.trips().map(\.label) == SeedScenario.hero.trips.reversed().map(\.name),
                "trip labels use gazetteer cities: Apple's Rumah is a locality, so the desert trip stays Saudi Arabia")
    }

    @Test func aPartyPastMidnightIsOneMoment() async throws {
        let (database, _, _) = try await build(SeedScenario.hero.libraryAssets)
        let party = SeedScenario.hero.items(.london).filter { $0.momentDay == LocalTime.day(year: 2021, month: 12, day: 31) && $0.title == "Tower Bridge" }
        let rows = try await derived(database)
        #expect(Set(party.compactMap { rows[$0.id]?.moment }).count == 1)
        #expect(party.count == 15)
    }

    // MARK: Zones

    @Test func zonesAreBorrowedWithinTwelveHoursElseHomeElseDevice() async throws {
        let athensNoon = Self.utc(2025, 3, 10, 12, in: Self.athens)
        let assets = [
            Fixture.photo("athens", athensNoon, at: Fixture.athens),
            Fixture.photo("after-11h", athensNoon + 11 * 3_600),
            Fixture.photo("after-13h", athensNoon + 13 * 3_600),
            // A tie: the earlier located photo wins.
            Fixture.photo("sydney", athensNoon - 30 * 3_600, at: Fixture.sydney),
            Fixture.photo("athens-early", athensNoon - 32 * 3_600, at: Fixture.athens),
            Fixture.photo("tie", athensNoon - 31 * 3_600),
        ]
        let (database, _, _) = try await build(assets)
        var rows = try await derived(database)
        #expect(rows["after-11h"]?.zone == "Europe/Athens")
        #expect(rows["after-11h"]?.zoneSource == ZoneSource.borrowed.rawValue)
        #expect(rows["after-13h"]?.zone == "Asia/Riyadh", "nothing within 12 h and no home: the device zone")
        #expect(rows["after-13h"]?.zoneSource == ZoneSource.device.rawValue)
        #expect(rows["tie"]?.zone == "Europe/Athens")

        // With a home base in 2025, the unborrowed photo takes the home zone instead.
        let (homed, _, _) = try await build(assets + Self.homeNights(2025, from: (6, 1)), zone: TimeZone(identifier: "America/New_York")!)
        rows = try await derived(homed)
        #expect(rows["after-13h"]?.zone == "Asia/Riyadh")
        #expect(rows["after-13h"]?.zoneSource == ZoneSource.home.rawValue)
    }

    @Test func aBorrowedZoneMovesAPhotoToItsDayAndBothDaysAreRebuilt() async throws {
        // 01:00 UTC in London is 01:00 local: still 9 March's moment day. A photo an hour later without GPS reads
        // 05:00 on 10 March in Riyadh (the device zone) until it borrows London's zone.
        let located = Self.utc(2025, 3, 10, 1, in: Self.london)
        let (database, _, _) = try await build([
            Fixture.photo("london", located, at: Coordinate(latitude: 51.5073, longitude: -0.1657)),
            Fixture.photo("later", located + 3_600),
        ])
        let rows = try await derived(database)
        let ninth = LocalTime.day(year: 2025, month: 3, day: 9)
        #expect(rows["later"]?.day == ninth)
        #expect(rows["later"]?.moment == rows["london"]?.moment)
        let moments = try await IndexReader(database: database).moments(after: nil, limit: 10)
        #expect(moments.map(\.key.day) == [ninth])
        #expect(try await Fixture.dirtyDays(database).isEmpty)
    }

    // MARK: Moments

    @Test func positionsAreBorrowedWithinTenMinutesOrTwoHoursOfTheirMoment() async throws {
        let start = Self.utc(2025, 3, 15, 17)
        let (database, _, _) = try await build([
            Fixture.photo("located", start, at: Fixture.nakheel),
            Fixture.photo("5min", start + 5 * 60),
            Fixture.photo("60min", start + 60 * 60),
            Fixture.photo("140min", start + 140 * 60),
        ])
        let rows = try await derived(database)
        #expect(rows["5min"]?.placeSource == PlaceSource.momentNear.rawValue)
        #expect(rows["5min"]?.effective == Fixture.nakheel)
        #expect(rows["5min"]?.city == "Riyadh")
        #expect(rows["60min"]?.placeSource == PlaceSource.momentFar.rawValue)
        #expect(rows["140min"]?.placeSource == PlaceSource.none.rawValue, "in the moment (80 min gaps) but 2 h 20 from the located photo")
        #expect(rows["140min"]?.effective == nil)
        #expect(rows["140min"]?.city == nil)
        #expect(Set(rows.values.map(\.moment)).count == 1)
        let moment = try #require(try await IndexReader(database: database).moments(after: nil, limit: 1).first)
        #expect(moment.locatedCount == 1)
        #expect(moment.borrowedCount == 2)
    }

    @Test func momentLabelsFollowTheirPrecedence() async throws {
        let day = (2026, 10, 10)
        func session(_ prefix: String, at place: Coordinate, hour: Int, count: Int = 4) -> [LibraryAsset] {
            (0..<count).map { Fixture.photo("\(prefix)\($0)", Self.utc(day.0, day.1, day.2, hour, $0 * 5), at: place) }
        }
        // Inside the park: 2 photos in its cell; 4 more 500–650 m east, outside its 400 m radius (2 of 6 = 33%).
        let spread = [Fixture.photo("spread0", Self.utc(day.0, day.1, day.2, 8), at: Fixture.nakheel),
                      Fixture.photo("spread1", Self.utc(day.0, day.1, day.2, 8, 1), at: Fixture.nakheel)]
            + [500.0, 550, 600, 650].enumerated().map { Fixture.photo("spread\($0.offset + 2)", Self.utc(day.0, day.1, day.2, 8, 2 + $0.offset),
                                                                      at: Self.east(of: Fixture.nakheel, $0.element)) }
        let assets = Self.homeNights(2026)
            + session("oia", at: Self.oia, hour: 10)
            + session("turaif", at: Self.atTuraif, hour: 14)
            + session("park", at: Fixture.nakheel, hour: 17)
            + session("home", at: Self.home, hour: 22, count: 1)
            + spread
        let (database, indexer, _) = try await build(assets)
        await Fixture.placeNames(database, indexer, maps: SeedMaps.client()).run()
        await indexer.settled()
        var rows = try await derived(database)
        #expect(rows["oia0"]?.momentLabel == "Oia", "Apple's locality where the gazetteer has none")
        #expect(rows["turaif0"]?.momentLabel == "At-Turaif", "an Apple Maps area covering the moment")
        #expect(rows["park0"]?.momentLabel == "Al-Nakheel Park")
        #expect(rows["home0"]?.momentLabel == "Home", "the home base before anything else")
        #expect(rows["spread0"]?.momentLabel == "Riyadh", "the park covers only a third of the moment: the city")

        // A saved place comes first of all.
        try await database.write { db in
            try db.execute(sql: "INSERT INTO place (kind, key, name, lat, lon, radius_m, source) VALUES (6, 'saved:1', 'My pitch', ?, ?, 250, 3)",
                           arguments: [Fixture.nakheel.latitude, Fixture.nakheel.longitude])
        }
        try await indexer.restructureAll()
        await indexer.settled()
        rows = try await derived(database)
        #expect(rows["park0"]?.momentLabel == "My pitch")

        // Without Apple Maps: the gazetteer locality, the city, the country.
        let (offline, _, _) = try await build(assets)
        rows = try await derived(offline)
        #expect(rows["turaif0"]?.momentLabel == "Ad Dir‘īyah")
        #expect(rows["park0"]?.momentLabel == "Riyadh")
        #expect(rows["oia0"]?.momentLabel == "Greece")
    }

    @Test func coversPreferAFavouriteThenTheMiddlePhoto() async throws {
        let start = Self.utc(2025, 3, 15, 17)
        let (database, _, _) = try await build((0..<5).map { Fixture.photo("p\($0)", start + Int64($0) * 60, at: Fixture.nakheel, favorite: $0 == 3) }
            + (0..<5).map { Fixture.photo("q\($0)", start + 86_400 + Int64($0) * 60, at: Fixture.nakheel, kind: $0 == 2 ? .video : .photo) })
        let moments = try await IndexReader(database: database).moments(after: nil, limit: 5)
        #expect(moments.map(\.coverLocalID) == ["q3", "p3"], "the middle photo (skipping the video), then the favourite")
    }

    // MARK: Home bases

    @Test func homeBasesUseNightsThenAllHoursThenInheritAndASavedHomeWins() async throws {
        let afternoons = (0..<11).map { index -> LibraryAsset in
            let date = LocalTime.civil(day: LocalTime.day(year: 2024, month: 2, day: 1) + Int32(index * 7))
            return Fixture.photo("work-\(index)", Self.utc(date.year, date.month, date.day, 14), at: Fixture.nakheel)
        }
        let assets = Self.homeNights(2025) + afternoons
            + (0..<15).map { Fixture.photo("park-2025-\($0)", Self.utc(2025, 6, 1 + $0, 15), at: Fixture.nakheel) }
            + [Fixture.photo("2023", Self.utc(2023, 5, 5, 12), at: Fixture.athens)]
        let (database, indexer, _) = try await build(assets)
        var homes = try await IndexQueries.homes(database)
        #expect(homes.map(\.year) == [2023, 2024, 2025])
        #expect(homes[2].source == .estimated)
        #expect(homes[2].center.distance(to: Self.home) < 1, "nights beat more afternoons elsewhere")
        #expect(homes[2].nights == 12)
        #expect(homes[1].source == .estimated)
        #expect(homes[1].center.distance(to: Fixture.nakheel) < 1, "no nights in 2024: ten days at any hour")
        #expect(homes[0].source == .inherited)
        #expect(homes[0].center == homes[1].center, "2023 borrows the nearest year's")

        try await database.write { db in
            try db.execute(sql: "INSERT INTO saved_place (name, name_folded, lat, lon, radius_m, is_home, created_utc, updated_utc) VALUES ('Home', 'home', ?, ?, 150, 1, 0, 0)",
                           arguments: [Self.oia.latitude, Self.oia.longitude])
            // As every write the library-wide steps read does (PR 3's saved places too).
            try Meta.markStructureDue(db)
        }
        await Fixture.sync(indexer, .restructure)
        homes = try await IndexQueries.homes(database)
        #expect(homes.allSatisfy { $0.source == .user && $0.center == Self.oia })
    }

    // MARK: Trips

    @Test func tripsAreRunsOfAwayDaysBetweenTwoAndThirtyDaysLong() async throws {
        func away(_ prefix: String, _ month: Int, _ days: [Int], at place: Coordinate = Fixture.athens) -> [LibraryAsset] {
            days.map { Fixture.photo("\(prefix)-\(month)-\($0)", Self.utc(2025, month, $0, 12, in: Self.athens), at: place) }
        }
        let assets = Self.homeNights(2025)
            + away("single", 3, [10])
            + away("bridged", 4, [1, 4])
            + away("split", 5, [1, 5])
            + away("broken", 6, [1, 3]) + [Fixture.photo("home-6-2", Self.utc(2025, 6, 2, 21), at: Self.home)]
            + away("month", 7, Array(1...31))
            + away("greece", 9, Array(1...10)) + away("islands", 9, Array(11...30), at: Self.oia)
        let (database, _, _) = try await build(assets)
        let trips = try await IndexReader(database: database).trips()
        let spans = trips.map { "\(LocalTime.civil(day: $0.startDay).month)/\(LocalTime.civil(day: $0.startDay).day)–\(LocalTime.civil(day: $0.endDay).month)/\(LocalTime.civil(day: $0.endDay).day)" }
        #expect(spans == ["9/1–9/30", "4/1–4/4"], "a day trip, days 4 apart, a home day between and a 31-day stay are not trips")
        #expect(trips.map(\.label) == ["Greece", "Athens"], "the city with 70% of the photos, else the country")
        #expect(trips.allSatisfy { $0.abroad && $0.countryCode == "GR" })
        #expect(trips[1].itemCount == 2)
        #expect(trips[1].maxKm > 2_000)
        let members = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE trip_id IS NOT NULL") }
        #expect(members == 32)
    }

    // MARK: Cells and counts

    @Test func cellsAreNamedOnlyWhenWorthItAndNeverAtHome() async throws {
        let old = Self.utc(2024, 3, 1, 12)
        let recent = Self.utc(2026, 10, 20, 12)
        let assets = Self.homeNights(2026, from: (3, 1))
            + (0..<3).map { Fixture.photo("three-\($0)", old + Int64($0) * 60, at: Fixture.athens) }
            + [Fixture.photo("two-days-0", old, at: Self.oia), Fixture.photo("two-days-1", old + 86_400, at: Self.oia)]
            + [Fixture.photo("lonely", old, at: Fixture.sydney)]
            + [Fixture.photo("recent", recent, at: Self.atTuraif)]
            + [Fixture.photo("near-home", Self.utc(2026, 3, 3, 12), at: Self.east(of: Self.home, 300))]
        let (database, indexer, _) = try await build(assets)
        #expect(await indexer.currentStatus().phase == .ready, "photos at the same second in three places: moments with distinct keys")
        let status = try await database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT cell, poi_status, needs_locality FROM cell").map { ($0["cell"] as String, [$0["poi_status"] as Int, $0["needs_locality"] as Int]) })
        }
        func cell(_ coordinate: Coordinate) -> [Int]? { status[GeoHash.encode(coordinate, precision: 7)] }
        #expect(cell(Self.home) == [PlaceNameStatus.skippedHome.rawValue, 0])
        #expect(cell(Fixture.athens)?.first == PlaceNameStatus.pending.rawValue, "3 photos")
        #expect(cell(Self.oia) == [PlaceNameStatus.pending.rawValue, 1], "2 days; no gazetteer city, so Apple's locality is asked for")
        #expect(cell(Fixture.sydney)?.first == PlaceNameStatus.ineligible.rawValue, "one old photo")
        #expect(cell(Self.atTuraif)?.first == PlaceNameStatus.pending.rawValue, "recent")
        #expect(cell(Self.east(of: Self.home, 300))?.first == PlaceNameStatus.ineligible.rawValue, "300 m from home is not home")
    }

    @Test func placesCountTheirPhotos() async throws {
        let (database, _, _) = try await build(SeedScenario.hero.libraryAssets)
        let counts = try await database.read { db in
            Dictionary(try Row.fetchAll(db, sql: "SELECT key, photo_count FROM place").map { ($0["key"] as String, $0["photo_count"] as Int) }, uniquingKeysWith: +)
        }
        let expected = try await database.read { db in
            (riyadh: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset a JOIN place p ON p.id IN (a.city_place, a.metro_place) WHERE p.key = 'gn:108410'") ?? -1,
             greece: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset a JOIN place p ON p.id = a.country_place WHERE p.key = 'cc:GR'") ?? -1)
        }
        #expect(counts["gn:108410"] == expected.riyadh)
        #expect(counts["cc:GR"] == expected.greece)
        #expect(counts["cc:GR"] == SeedScenario.hero.items(.greece).filter(\.isLocated).count)
        #expect(counts["home"] == SeedScenario.hero.items(.home).count + SeedScenario.hero.items(.summer2026).count)
    }

    // MARK: Incremental changes

    @Test func twoMomentsInTheSameSecondSurviveTheFirstGrowingOrGoing() async throws {
        // Two cameras 3 km apart in the same second: the second moment starts a second later to keep (day, start) unique.
        let second = Self.utc(2025, 4, 5, 17)
        let (database, indexer, reader) = try await build([
            Fixture.photo("x", second, at: Fixture.nakheel), Fixture.photo("y", second, at: Self.east(of: Fixture.nakheel, 3_000)),
        ])
        var starts = try await IndexReader(database: database).moments(after: nil, limit: 5).map(\.key.startUTC)
        #expect(starts.sorted() == [second, second + 1])

        // An earlier photo joins the first moment: the second no longer needs the extra second and takes the first's old start.
        reader.insert([Fixture.photo("x0", second - 60, at: Fixture.nakheel)])
        await Fixture.sync(indexer, .sync(.foreground))
        #expect(await indexer.currentStatus().phase == .ready)
        starts = try await IndexReader(database: database).moments(after: nil, limit: 5).map(\.key.startUTC)
        #expect(starts.sorted() == [second - 60, second])
        #expect(try await Fixture.dirtyDays(database).isEmpty)
        #expect(try await Fixture.structure(database) == Fixture.structure(Fixture.cleanBuild(of: reader, structured: true)))

        reader.delete(["x0", "x"])
        await Fixture.sync(indexer, .sync(.foreground))
        #expect(await indexer.currentStatus().phase == .ready)
        #expect(try await Fixture.structure(database) == Fixture.structure(Fixture.cleanBuild(of: reader, structured: true)))
    }

    @Test func aBorrowedZoneThatKeepsTheDayRebuildsTheMoment() async throws {
        // 06:00 UTC without GPS and nothing within 12 h: the device zone, 09:00 in Riyadh on 11 March.
        let gpsless = Self.utc(2025, 3, 11, 6, in: .gmt)
        let (database, indexer, reader) = try await build([Fixture.photo("g", gpsless)])
        // A London photo 8 h earlier, on 10 March: the photo borrows London's zone, 06:00 and still 11 March.
        reader.insert([Fixture.photo("london", gpsless - 8 * 3_600, at: Coordinate(latitude: 51.5073, longitude: -0.1657))])
        await Fixture.sync(indexer, .sync(.foreground))
        let rows = try await derived(database)
        #expect(rows["g"]?.zone == "Europe/London")
        #expect(rows["g"]?.day == LocalTime.day(year: 2025, month: 3, day: 11))
        #expect(try await Fixture.structure(database) == Fixture.structure(Fixture.cleanBuild(of: reader, structured: true)))
    }

    @Test func aNewDeviceZoneThatKeepsTheDayRebuildsTheMoment() async throws {
        let dubai = TimeZone(identifier: "Asia/Dubai")!
        let reader = FakeLibraryReader(.explicit([Fixture.photo("g", Self.utc(2025, 3, 11, 12))]))
        let database = try IndexDatabase.open(.inMemory)
        await Fixture.sync(Fixture.structured(database, reader))
        // 15:00 in Riyadh, 16:00 in Dubai: the same day, another time and zone.
        await Fixture.sync(Fixture.structured(database, reader, zone: { dubai }))
        let moment = try #require(try await IndexReader(database: database).moments(after: nil, limit: 1).first)
        #expect(moment.timeZone == "Asia/Dubai")
        #expect(try await Fixture.structure(database) == Fixture.structure(Fixture.cleanBuild(of: reader, structured: true, zone: { dubai })))
    }

    @Test func undatedPhotosWithGPSArePlacedToo() async throws {
        let (database, indexer, reader) = try await build([
            Fixture.photo("dated", Self.utc(2025, 5, 1, 12), at: Fixture.athens), Fixture.photo("undated", nil, at: Fixture.nakheel),
        ])
        let rows = try await derived(database)
        #expect(rows["undated"]?.day == nil)
        #expect(rows["undated"]?.city == "Riyadh")
        #expect(rows["undated"]?.country == "SA")
        #expect(try await IndexReader(database: database).summary().countries == 2)

        reader.insert([Fixture.photo("undated-sydney", nil, at: Fixture.sydney)])
        await Fixture.sync(indexer, .sync(.foreground))
        #expect(try await IndexReader(database: database).summary().countries == 3)
        #expect(try await Fixture.structure(database) == Fixture.structure(Fixture.cleanBuild(of: reader, structured: true)))
    }

    @Test func aSyncThatChangedNothingSkipsTheLibraryWideSteps() async throws {
        let park = GeoHash.encode(Fixture.nakheel, precision: 7)
        let (database, indexer, reader) = try await build([Fixture.photo("p0", Self.utc(2025, 6, 1, 17), at: Fixture.nakheel)])
        func photos() async throws -> Int? {
            try await database.read { db in try Int.fetchOne(db, sql: "SELECT photo_count FROM cell WHERE cell = ?", arguments: [park]) }
        }
        func tamper() async throws {
            try await database.write { db in try db.execute(sql: "UPDATE cell SET photo_count = 99 WHERE cell = ?", arguments: [park]) }
        }
        #expect(try await Fixture.meta(database).phase == .idle)
        #expect(try await database.read { db in try Meta.int(db, .structureDue) } == nil, "cleared by the final run")

        try await tamper()
        await Fixture.sync(indexer, .sync(.foreground))
        #expect(try await photos() == 99, "nothing changed, so cells weren't recomputed")

        // A run stopped before its last step leaves it due.
        try await database.write { db in try Meta.markStructureDue(db) }
        await Fixture.sync(indexer, .sync(.foreground))
        #expect(try await photos() == 1)

        // So does a new photo.
        try await tamper()
        reader.insert([Fixture.photo("p1", Self.utc(2025, 6, 2, 17), at: Fixture.nakheel)])
        await Fixture.sync(indexer, .sync(.foreground))
        #expect(try await photos() == 2)
    }

    @Test func aCityCentreMomentIsNamedForTheCityRatherThanANeighbouringLocality() async throws {
        // At the Acropolis the gazetteer's locality is Dhafní, a separate town 2.4 km south; Athens' point is nearer.
        let (database, _, _) = try await build((0..<4).map { Fixture.photo("a\($0)", Self.utc(2025, 7, 3, 10, $0 * 5, in: Self.athens), at: Fixture.athens) })
        let rows = try await derived(database)
        #expect(rows["a0"]?.city == "Athens")
        #expect(rows["a0"]?.locality == "Dhafní", "the asset keeps its locality")
        #expect(rows["a0"]?.momentLabel == "Athens")

        // Nearer its locality than its city's point, a moment keeps the locality's name.
        let towerBridge = try #require(SeedScenario.hero.items(.london).first { $0.title == "Tower Bridge" })
        let hero = try await derived(build(SeedScenario.hero.libraryAssets).0)
        let party = try #require(hero[towerBridge.id])
        #expect(party.locality != nil)
        #expect(party.momentLabel == party.locality)
    }

    @Test func aPlaceFirstUsedAsALocalityBecomesACityInTheSameTransaction() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let kind = try await database.write { db -> Int? in
            var rows = PlaceRows(db)
            let locality = PlaceSpec(key: "gn:1", kind: .locality, name: "Town", names: ["Town"], source: .gazetteer)
            var city = locality
            city.kind = .city
            let first = try rows.id(locality)
            #expect(try rows.id(city) == first)
            #expect(try rows.id(locality) == first)
            return try Int.fetchOne(db, sql: "SELECT kind FROM place WHERE id = ?", arguments: [first])
        }
        #expect(kind == PlaceKind.city.rawValue)
    }

    // MARK: Incremental equals a clean build

    @Test(arguments: 0..<6) func randomChangesRestructuredIncrementallyEqualACleanBuild(seed: UInt64) async throws {
        var random = SplitMix(seed: seed + 500)
        let places = [Self.home, Fixture.nakheel, Fixture.athens, Self.oia, Fixture.sydney]
        let start = Self.utc(2025, 1, 1, 0)
        func asset(_ id: String) -> LibraryAsset {
            let place = Int.random(in: 0..<3, using: &random) == 0 ? nil : places.randomElement(using: &random)
            return Fixture.photo(id, start + Int64.random(in: 0...(400 * 86_400), using: &random), at: place,
                                 favorite: Int.random(in: 0..<8, using: &random) == 0)
        }
        let reader = FakeLibraryReader(.explicit(Self.homeNights(2025) + (0..<60).map { asset("a\($0)") }))
        let database = try IndexDatabase.open(.inMemory)
        let indexer = Fixture.structured(database, reader, settings: IndexerSettings(batchSize: 9))
        await Fixture.sync(indexer)
        var serial = 0
        for round in 0..<5 {
            for _ in 0..<Int.random(in: 1...6, using: &random) {
                let existing = reader.allAssets
                switch Int.random(in: 0..<4, using: &random) {
                case 0:
                    serial += 1
                    reader.insert([asset("n\(serial)")])
                case 1:
                    guard var changed = existing.randomElement(using: &random) else { continue }
                    let moved = asset(changed.id)
                    if Bool.random(using: &random) { changed.facts.coordinate = moved.facts.coordinate } else { changed.facts.creationDate = moved.facts.creationDate }
                    reader.update([changed])
                case 2:
                    guard let gone = existing.randomElement(using: &random) else { continue }
                    reader.delete([gone.id])
                default:
                    // Copies a photo a few minutes later without GPS (borrowing within moments).
                    guard let source = existing.randomElement(using: &random), let date = source.facts.creationDate else { continue }
                    serial += 1
                    reader.insert([Fixture.photo("c\(serial)", Int64(date.timeIntervalSince1970) + Int64.random(in: -9_000...9_000, using: &random))])
                }
            }
            await Fixture.sync(indexer, .sync(.foreground))
            let clean = try await Fixture.cleanBuild(of: reader, structured: true)
            #expect(try await Fixture.structure(database) == Fixture.structure(clean), "seed \(seed), round \(round)")
        }
    }
}

extension IndexQueries {
    /// Every home base, oldest first (tests).
    static func homes(_ database: IndexDatabase) async throws -> [HomeBaseRow] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT h.year, h.lat, h.lon, h.tile, zone.name AS zone, h.country_code, h.nights, h.source FROM home_base h LEFT JOIN zone ON zone.id = h.tz ORDER BY h.year
                """).map { row in
                HomeBaseRow(year: row["year"], center: Coordinate(latitude: row["lat"], longitude: row["lon"]), tile: row["tile"], timeZone: row["zone"],
                            countryCode: row["country_code"], nights: row["nights"], source: HomeBaseRow.Source(rawValue: row["source"]) ?? .estimated)
            }
        }
    }
}
