import Foundation
import LZGeo
internal import GRDB

/// `cell.poi_status`: where Apple Maps naming is for a cell. The indexer moves cells between pending, skipped
/// near home and ineligible; the place-name queue writes the rest.
enum PlaceNameStatus: Int, Sendable, CaseIterable {
    case pending = 0, named = 1, none = 2, retry = 3, gaveUp = 4, skippedHome = 5, ineligible = 6

    /// The statuses the indexer decides (from counts and home bases); the others are the queue's results.
    static let indexerOwned: Set<PlaceNameStatus> = [.pending, .skippedHome, .ineligible]
}

/// The geohash-7 cells holding located photos: their aggregates and whether Apple Maps naming applies (search
/// spec §4.4). A cell is eligible with at least 3 photos, photos on 2 days, or a photo in the last 90 days;
/// cells within 150 m of a home base are skipped, so the home is never sent. Only the aggregate columns and the
/// indexer's statuses are written here; the place-name queue owns the rest.
enum CellAggregator {
    static let nearHomeMetres: Double = 150
    static let recentSeconds: Int64 = 90 * 86_400

    private struct Values: Hashable {
        var lat: Double
        var lon: Double
        var photos: Int
        var days: Int
        var last: Int64?
        var nearHome: Bool
        var needsLocality: Bool
        var status: Int
    }

    /// Recomputes every cell. Returns how many rows changed.
    static func update(_ db: Database, geo: GeoCache, now: Date) throws -> Int {
        let homes = try Row.fetchAll(db, sql: "SELECT lat, lon FROM home_base").map { Coordinate(latitude: $0["lat"], longitude: $0["lon"]) }
        var existing: [String: Values] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT cell, lat, lon, photo_count, day_count, last_utc, near_home, needs_locality, poi_status FROM cell") {
            existing[row["cell"]] = Values(lat: row["lat"], lon: row["lon"], photos: row["photo_count"], days: row["day_count"], last: row["last_utc"],
                                           nearHome: row["near_home"], needsLocality: row["needs_locality"], status: row["poi_status"])
        }
        let recent = Int64(now.timeIntervalSince1970) - recentSeconds
        var changes = 0
        let upsert = try db.cachedStatement(sql: """
            INSERT INTO cell (cell, lat, lon, photo_count, day_count, last_utc, near_home, needs_locality, poi_status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(cell) DO UPDATE SET lat = excluded.lat, lon = excluded.lon, photo_count = excluded.photo_count, day_count = excluded.day_count,
              last_utc = excluded.last_utc, near_home = excluded.near_home, needs_locality = excluded.needs_locality,
              poi_status = CASE WHEN cell.poi_status IN (0, 5, 6) THEN excluded.poi_status ELSE cell.poi_status END
            """)
        let rows = try Row.fetchAll(db, sql: """
            SELECT cell, AVG(lat) AS lat, AVG(lon) AS lon, COUNT(*) AS photos, COUNT(DISTINCT day) AS days, MAX(created_utc) AS last
            FROM asset WHERE cell IS NOT NULL GROUP BY cell
            """)
        var seen = Set<String>()
        for row in rows {
            let hash: String = row["cell"]
            seen.insert(hash)
            // Rounded, so the same members give the same centroid whatever order SQLite adds them in.
            let centroid = Coordinate(latitude: ((row["lat"] as Double) * 1e7).rounded() / 1e7, longitude: ((row["lon"] as Double) * 1e7).rounded() / 1e7)
            let photos: Int = row["photos"], days: Int = row["days"], last: Int64? = row["last"]
            let nearHome = homes.contains { $0.distance(to: centroid) <= nearHomeMetres }
            let eligible = photos >= 3 || days >= 2 || (last ?? .min) >= recent
            let decided: PlaceNameStatus = nearHome ? .skippedHome : eligible ? .pending : .ineligible
            let old = existing[hash]
            let status = old.map { PlaceNameStatus.indexerOwned.contains(PlaceNameStatus(rawValue: $0.status) ?? .pending) ? decided.rawValue : $0.status }
                ?? decided.rawValue
            let values = Values(lat: centroid.latitude, lon: centroid.longitude, photos: photos, days: days, last: last, nearHome: nearHome,
                                needsLocality: geo.cell(hash).city == nil, status: status)
            guard values != old else { continue }
            try upsert.execute(arguments: [hash, values.lat, values.lon, photos, days, last, nearHome, values.needsLocality, decided.rawValue])
            changes += 1
        }
        for hash in existing.keys where !seen.contains(hash) {
            try db.execute(sql: "DELETE FROM cell WHERE cell = ?", arguments: [hash])
            changes += 1
        }
        return changes
    }
}

/// Photo counts per place (search spec §4.4): countries, regions, cities (as city or metro) and localities from
/// the asset columns; areas (Apple Maps places, saved places, home) from the photos of the cells whose centroid
/// is within their radius.
enum PlaceCounts {
    /// Grid buckets for the area counts, in degrees (about 5.5 km).
    static let bucket = 0.05

    /// Recounts every place. Returns how many rows changed.
    static func update(_ db: Database) throws -> Int {
        var counts: [Int64: (photos: Int, last: Int64?)] = [:]
        for column in ["country_place", "region_place", "locality_place"] {
            for row in try Row.fetchAll(db, sql: "SELECT \(column) AS place, COUNT(*) AS photos, MAX(created_utc) AS last FROM asset WHERE \(column) IS NOT NULL GROUP BY \(column)") {
                counts[row["place"]] = (row["photos"], row["last"])
            }
        }
        // A city counts its own photos and those it is the metro of, each once.
        for row in try Row.fetchAll(db, sql: """
            SELECT place, COUNT(*) AS photos, MAX(created_utc) AS last FROM (
              SELECT id, created_utc, city_place AS place FROM asset WHERE city_place IS NOT NULL
              UNION SELECT id, created_utc, metro_place AS place FROM asset WHERE metro_place IS NOT NULL)
            GROUP BY place
            """) {
            counts[row["place"]] = (row["photos"], row["last"])
        }

        // Areas: cells bucketed on a coarse grid, then each area scans the buckets its radius reaches.
        var grid: [Int64: [(center: Coordinate, photos: Int, last: Int64?)]] = [:]
        func key(_ row: Int, _ column: Int) -> Int64 { Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(column))) }
        for row in try Row.fetchAll(db, sql: "SELECT lat, lon, photo_count, last_utc FROM cell") {
            let center = Coordinate(latitude: row["lat"], longitude: row["lon"])
            grid[key(Int((center.latitude / bucket).rounded(.down)), Int((center.longitude / bucket).rounded(.down))), default: []]
                .append((center, row["photo_count"], row["last_utc"]))
        }
        let areaKinds = [PlaceKind.poi, .saved, .home, .mapResult].map { String($0.rawValue) }.joined(separator: ", ")
        for row in try Row.fetchAll(db, sql: "SELECT id, lat, lon, radius_m FROM place WHERE kind IN (\(areaKinds)) AND lat IS NOT NULL AND radius_m IS NOT NULL") {
            let center = Coordinate(latitude: row["lat"], longitude: row["lon"])
            let radius: Double = row["radius_m"]
            let latitudeSpan = radius / 111_320, longitudeSpan = radius / (111_320 * max(0.01, cos(center.latitude * .pi / 180)))
            var photos = 0
            var last: Int64?
            let rows = Int(((center.latitude - latitudeSpan) / bucket).rounded(.down))...Int(((center.latitude + latitudeSpan) / bucket).rounded(.down))
            let columns = Int(((center.longitude - longitudeSpan) / bucket).rounded(.down))...Int(((center.longitude + longitudeSpan) / bucket).rounded(.down))
            for gridRow in rows {
                for column in columns {
                    for cell in grid[key(gridRow, column)] ?? [] where cell.center.distance(to: center) <= radius {
                        photos += cell.photos
                        last = max(last ?? .min, cell.last ?? .min)
                    }
                }
            }
            if photos > 0 { counts[row["id"]] = (photos, last) }
        }

        var changes = 0
        let update = try db.cachedStatement(sql: "UPDATE place SET photo_count = ?, last_utc = ? WHERE id = ?")
        for row in try Row.fetchAll(db, sql: "SELECT id, photo_count, last_utc FROM place") {
            let id: Int64 = row["id"]
            let count = counts[id] ?? (0, nil)
            guard count.photos != row["photo_count"] || count.last != row["last_utc"] else { continue }
            try update.execute(arguments: [count.photos, count.last, id])
            changes += 1
        }
        return changes
    }
}
