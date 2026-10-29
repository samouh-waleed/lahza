import Foundation
import LZGeo
internal import GRDB

/// The home base of every local year (search spec §4.4):
/// 1. Located photos taken between 19:00 and 07:00 ("nights"); count distinct moment days per geohash-6 tile.
/// 2. The tile with the most night days wins if it has at least 10; a tie goes to the most recent.
/// 3. Otherwise the same over all hours. Otherwise the nearest year with a home lends its own (inherited).
/// 4. The point is the median of those photos in the tile and its 8 neighbours.
/// 5. A saved place marked as home overrides every year.
///
/// The `home` place row mirrors the latest year. A changed home moves the zones its year's GPS-less assets
/// fall back to and the labels of moments near it, so those days are marked dirty.
enum HomeBaseFinder {
    static let minimumDays = 10
    /// Night: from 19:00 to 07:00 local time.
    static let nightStart = 19 * 60
    static let nightEnd = 7 * 60

    enum Source: Int {
        case estimated = 0, inherited = 1, user = 2
    }

    struct Home: Hashable {
        var year: Int
        var center: Coordinate
        var tile: String
        var zone: Int64?
        var countryCode: String?
        var nights: Int
        var source: Source
    }

    /// Recomputes every year's home, writes what changed and marks the affected days dirty. Returns whether
    /// anything changed.
    static func update(_ db: Database, geo: GeoCache) throws -> Bool {
        let old = try current(db)
        var zones = ZoneTable(try Row.fetchAll(db, sql: "SELECT id, name FROM zone"))
        let new = try compute(db, geo: geo, zones: &zones)
        guard new != old else { return false }

        for year in Set(old.keys).union(new.keys) where old[year] != new[year] {
            let before = old[year], after = new[year]
            if let after {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO home_base (year, lat, lon, tile, tz, country_code, nights, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [year, after.center.latitude, after.center.longitude, after.tile, after.zone, after.countryCode, after.nights,
                                     after.source.rawValue])
            } else {
                try db.execute(sql: "DELETE FROM home_base WHERE year = ?", arguments: [year])
            }
            // Only the point and the zone change what assets borrow and how moments are labelled.
            guard before?.center != after?.center || before?.zone != after?.zone else { continue }
            var tiles = Set<String>()
            for center in [before?.center, after?.center].compactMap({ $0 }) {
                let tile = GeoHash.encode(center, precision: 6)
                tiles.insert(tile)
                tiles.formUnion(GeoHash.neighbours(tile))
            }
            let first = LocalTime.day(year: year, month: 1, day: 1), last = LocalTime.day(year: year + 1, month: 1, day: 1) - 1
            try db.execute(sql: """
                INSERT OR IGNORE INTO dirty_day SELECT DISTINCT day FROM asset
                WHERE day BETWEEN ? AND ? AND (tz_src IN (?, ?) OR substr(cell, 1, 6) IN (\(tiles.map { _ in "?" }.joined(separator: ", "))))
                """, arguments: StatementArguments([first, last, ZoneSource.home.rawValue, ZoneSource.device.rawValue] as [any DatabaseValueConvertible]
                                                + tiles.sorted().map { $0 as any DatabaseValueConvertible }))
        }

        // The `home` place mirrors the latest year.
        if let latest = new.values.max(by: { $0.year < $1.year }) {
            var places = PlaceRows(db)
            _ = try places.id(PlaceSpec(key: "home", kind: .home, name: "Home", names: ["Home"], category: .home, coordinate: latest.center,
                                        radius: DayContext.homeRadius, countryCode: latest.countryCode,
                                        source: latest.source == .user ? .user : .inferred), refresh: true)
        } else {
            try db.execute(sql: "DELETE FROM place WHERE key = 'home'")
        }
        return true
    }

    static func current(_ db: Database) throws -> [Int: Home] {
        var homes: [Int: Home] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM home_base") {
            homes[row["year"]] = Home(year: row["year"], center: Coordinate(latitude: row["lat"], longitude: row["lon"]), tile: row["tile"],
                                      zone: row["tz"], countryCode: row["country_code"], nights: row["nights"],
                                      source: Source(rawValue: row["source"]) ?? .estimated)
        }
        return homes
    }

    /// Every year's home from the located assets.
    static func compute(_ db: Database, geo: GeoCache, zones: inout ZoneTable) throws -> [Int: Home] {
        guard let range = try Row.fetchOne(db, sql: "SELECT MIN(day) AS first, MAX(day) AS last FROM asset WHERE day IS NOT NULL AND flags & 32 = 0"),
              let firstDay = range["first"] as Int32?, let lastDay = range["last"] as Int32? else { return [:] }
        let years = firstDay.civilYear...lastDay.civilYear

        func home(_ year: Int, _ center: Coordinate, tile: String, nights: Int, source: Source) throws -> Home {
            Home(year: year, center: center, tile: tile, zone: try zones.id(geo.gazetteer.timeZoneIdentifier(at: center), db),
                 countryCode: geo.gazetteer.locate(center).countryCode, nights: nights, source: source)
        }

        if let saved = try Row.fetchOne(db, sql: "SELECT lat, lon FROM saved_place WHERE is_home = 1") {
            let center = Coordinate(latitude: saved["lat"], longitude: saved["lon"])
            let tile = GeoHash.encode(center, precision: 6)
            var homes: [Int: Home] = [:]
            for year in years { homes[year] = try home(year, center, tile: tile, nights: 0, source: .user) }
            return homes
        }

        /// Per year and tile: the distinct days, the latest day and the photos, at night and at any hour.
        struct Tile {
            var nightDays = Set<Int32>()
            var allDays = Set<Int32>()
            var latestNight: Int32 = .min
            var latest: Int32 = .min
            var night: [Coordinate] = []
            var all: [Coordinate] = []
        }
        var tiles: [Int: [String: Tile]] = [:]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT day, wall_s, lat, lon, cell FROM asset WHERE lat IS NOT NULL AND cell IS NOT NULL AND day IS NOT NULL AND wall_s IS NOT NULL AND flags & 32 = 0
            """)
        while let row = try rows.next() {
            let day: Int32 = row["day"]
            let cell: String = row["cell"]
            let coordinate = Coordinate(latitude: row["lat"], longitude: row["lon"])
            let minute = LocalTime.minuteOfDay(wallSeconds: row["wall_s"])
            let isNight = minute >= nightStart || minute < nightEnd
            let tile = String(cell.prefix(6))
            var entry = tiles[day.civilYear, default: [:]][tile, default: Tile()]
            entry.allDays.insert(day)
            entry.latest = max(entry.latest, day)
            entry.all.append(coordinate)
            if isNight {
                entry.nightDays.insert(day)
                entry.latestNight = max(entry.latestNight, day)
                entry.night.append(coordinate)
            }
            tiles[day.civilYear, default: [:]][tile] = entry
        }

        var own: [Int: Home] = [:]
        for (year, yearTiles) in tiles {
            func best(_ days: (Tile) -> Int, _ latest: (Tile) -> Int32) -> (tile: String, count: Int)? {
                yearTiles.map { (tile: $0.key, count: days($0.value), latest: latest($0.value)) }
                    .filter { $0.count >= minimumDays }
                    .max { ($0.count, $0.latest, $1.tile) < ($1.count, $1.latest, $0.tile) }
                    .map { ($0.tile, $0.count) }
            }
            let atNight = best({ $0.nightDays.count }, { $0.latestNight })
            guard let winner = atNight ?? best({ $0.allDays.count }, { $0.latest }) else { continue }
            let area = [winner.tile] + GeoHash.neighbours(winner.tile)
            let photos = area.flatMap { tile -> [Coordinate] in
                guard let entry = yearTiles[tile] else { return [] }
                return atNight != nil ? entry.night : entry.all
            }
            let center = Coordinate(latitude: DayBuilder.median(photos.map(\.latitude)), longitude: DayBuilder.median(photos.map(\.longitude)))
            own[year] = try home(year, center, tile: winner.tile, nights: winner.count, source: .estimated)
        }
        guard !own.isEmpty else { return [:] }

        var homes = own
        for year in years where own[year] == nil {
            // The nearest year with its own home; a tie goes to the later one.
            guard let lender = own.keys.min(by: { (abs($0 - year), -$0) < (abs($1 - year), -$1) }), let source = own[lender] else { continue }
            var inherited = source
            inherited.year = year
            inherited.nights = 0
            inherited.source = .inherited
            homes[year] = inherited
        }
        return homes
    }
}
