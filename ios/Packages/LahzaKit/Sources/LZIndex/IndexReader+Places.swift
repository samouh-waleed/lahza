import Foundation
import LZGeo
internal import GRDB

/// The place queries search needs: names (FTS5, then a typo pass), places by kind or key, remembered picks, the
/// Apple Maps search cache, saved places and photo counts around a point.
extension IndexReader {
    /// Places with a name matching `phrase`, best first: FTS5 over every folded variant of the phrase (each word
    /// whole, the last one also as a prefix), ranked by how the name matched, then bm25, then photo count. When
    /// nothing matches, a typo pass looks at the names of places with photos: every word of 3 or more letters must
    /// be within one edit of a word of the name (shorter words must be equal). One row per place.
    public func searchPlaces(_ phrase: String, limit: Int) async throws -> [PlaceRow] {
        let variants = PlaceNames.variants(phrase)
        guard !variants.isEmpty, limit > 0 else { return [] }
        return try await database.read { db in
            var best: [Int64: (row: PlaceRow, rank: Double)] = [:]
            for variant in variants {
                let words = variant.split(separator: " ").map(String.init)
                let query = words.enumerated().map { index, word in "\"\(word)\"" + (index == words.count - 1 ? "*" : "") }.joined(separator: " ")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT \(PlaceQueries.columns), n.name AS matched, bm25(place_fts) AS rank
                    FROM place_fts JOIN place_name n ON n.id = place_fts.rowid JOIN place p ON p.id = n.place_id
                    WHERE place_fts MATCH ? ORDER BY rank LIMIT ?
                    """, arguments: [query, limit * 8])
                for row in rows {
                    let matched: String = row["matched"]
                    let match: PlaceMatch = matched == variant ? .exact
                        : Set(words).isSubset(of: matched.split(separator: " ").map(String.init)) ? .allTokens : .prefix
                    var place = PlaceQueries.place(row)
                    place.matchedName = matched
                    place.match = match
                    let rank: Double = row["rank"]
                    if let current = best[place.id], (current.row.match ?? .typo, current.rank) <= (match, rank) { continue }
                    best[place.id] = (place, rank)
                }
            }
            if best.isEmpty { return try PlaceQueries.typoMatches(db, words: variants[0].split(separator: " ").map(String.init), limit: limit) }
            return best.values.sorted { lhs, rhs in
                (lhs.row.match ?? .typo, lhs.rank, -lhs.row.photoCount, lhs.row.id) < (rhs.row.match ?? .typo, rhs.rank, -rhs.row.photoCount, rhs.row.id)
            }.prefix(limit).map(\.row)
        }
    }

    /// Places of these kinds with at least `minPhotos` photos, most photographed first.
    public func places(kinds: Set<PlaceKind>, minPhotos: Int, limit: Int) async throws -> [PlaceRow] {
        guard !kinds.isEmpty, limit > 0 else { return [] }
        let list = kinds.map { String($0.rawValue) }.sorted().joined(separator: ", ")
        return try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(PlaceQueries.columns) FROM place p WHERE p.kind IN (\(list)) AND p.photo_count >= ? ORDER BY p.photo_count DESC, p.id LIMIT ?
                """, arguments: [minPhotos, limit]).map(PlaceQueries.place)
        }
    }

    /// The places with these keys (missing keys are left out).
    public func places(keys: [String]) async throws -> [String: PlaceRow] {
        guard !keys.isEmpty else { return [:] }
        return try await database.read { db in
            var found: [String: PlaceRow] = [:]
            for start in stride(from: 0, to: keys.count, by: 900) {
                let chunk = keys[start..<min(keys.count, start + 900)]
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                for row in try Row.fetchAll(db, sql: "SELECT \(PlaceQueries.columns) FROM place p WHERE p.key IN (\(marks))", arguments: StatementArguments(chunk)) {
                    let place = PlaceQueries.place(row)
                    found[place.key] = place
                }
            }
            return found
        }
    }

    /// The place the person picked the last time they searched `folded` (a ``PlaceNames/fold(_:)`` phrase).
    public func placeChoice(for folded: String) async throws -> PlaceChoiceRow? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT phrase, place_key, radius_m, updated_utc FROM place_choice WHERE phrase = ?", arguments: [PlaceNames.fold(folded)])
                .map { row in
                    PlaceChoiceRow(phrase: row["phrase"], placeKey: row["place_key"], radius: row["radius_m"],
                                   updated: Date(timeIntervalSince1970: TimeInterval(row["updated_utc"] as Int64)))
                }
        }
    }

    /// Apple Maps' answer to an earlier search under `key`, if it was fetched within `maxAge` of `now` (an empty
    /// array is a remembered "nothing found"); nil when there is no fresh answer.
    public func cachedMapSearch(key: String, maxAge: Duration, now: Date) async throws -> [MapPlace]? {
        let oldest = Int64(now.timeIntervalSince1970) - maxAge.components.seconds
        let payload = try await database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM map_search_cache WHERE key = ? AND fetched_at >= ?", arguments: [key, oldest])
        }
        guard let payload else { return nil }
        return try? JSONDecoder().decode([MapPlace].self, from: payload)
    }

    /// Photos and videos whose position (their own GPS, or one borrowed from their moment) is within `radius`
    /// metres of `c`.
    public func countWithin(_ c: Coordinate, radius: Double) async throws -> Int {
        try await PlaceQueries.distances(database, from: c, within: radius, columns: ("eff_lat", "eff_lon")).count
    }

    /// The distances, in metres, of the photos with their own GPS within `radius` of `c` (search's hull refinement
    /// of an area's radius).
    public func ownDistances(from c: Coordinate, within radius: Double) async throws -> [Double] {
        try await PlaceQueries.distances(database, from: c, within: radius, columns: ("lat", "lon"))
    }

    /// Every saved place, by name.
    public func savedPlaces() async throws -> [SavedPlaceRow] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, lat, lon, radius_m, is_home FROM saved_place ORDER BY name_folded").map { row in
                SavedPlaceRow(id: row["id"], name: row["name"], center: Coordinate(latitude: row["lat"], longitude: row["lon"]),
                              radius: row["radius_m"], isHome: row["is_home"])
            }
        }
    }

    /// What Lahza uses as home: a saved place set as home, the person's "No home", or the estimate (the latest home base).
    public func homeSetting() async throws -> HomeSetting {
        if let saved = try await savedPlaces().first(where: \.isHome) { return .saved(saved) }
        let none = try await database.read { db in try Meta.string(db, .homeOverride) == HomeOverride.none.rawValue }
        if none { return .noHome }
        return .estimated(try await homeBase(year: nil))
    }

    /// The places where photos are taken at night (geohash-6 tiles, 19:00–07:00 local), most nights first, with the
    /// name most of their night photos' moments carry (their town or city where that is the home): Settings' home
    /// choices. `isEstimate` marks the tile the home
    /// rule picks without the person's choice (the latest year's best tile with enough nights).
    public func homeCandidates(limit: Int) async throws -> [HomeCandidate] {
        guard limit > 0 else { return [] }
        return try await database.read { db in
            struct Tile {
                var days = Set<Int32>()
                var latest: Int32 = .min
                var latitudes: [Double] = []
                var longitudes: [Double] = []
                var places: [Int64: Int] = [:]
                var nightsByYear: [Int: Set<Int32>] = [:]
            }
            var tiles: [String: Tile] = [:]
            // Named by their moments' labels (a park, a hotel, a town), else their town or city; never by the home label.
            let rows = try Row.fetchCursor(db, sql: """
                SELECT a.day, a.wall_s, a.lat, a.lon, a.cell,
                       COALESCE(CASE WHEN label.kind <> \(PlaceKind.home.rawValue) THEN label.id END, a.locality_place, a.city_place) AS place
                FROM asset a LEFT JOIN moment m ON m.id = a.moment_id LEFT JOIN place label ON label.id = m.label_place
                WHERE a.lat IS NOT NULL AND a.cell IS NOT NULL AND a.day IS NOT NULL AND a.wall_s IS NOT NULL AND a.flags & 32 = 0
                """)
            while let row = try rows.next() {
                let minute = LocalTime.minuteOfDay(wallSeconds: row["wall_s"])
                guard minute >= HomeBaseFinder.nightStart || minute < HomeBaseFinder.nightEnd else { continue }
                let cell: String = row["cell"], day: Int32 = row["day"]
                let key = String(cell.prefix(6))
                var tile = tiles[key, default: Tile()]
                tile.days.insert(day)
                tile.latest = max(tile.latest, day)
                tile.latitudes.append(row["lat"])
                tile.longitudes.append(row["lon"])
                if let place: Int64 = row["place"] { tile.places[place, default: 0] += 1 }
                tile.nightsByYear[day.civilYear, default: []].insert(day)
                tiles[key] = tile
            }
            // The home rule's pick: the latest year with a tile of enough nights, its best tile (a tie: the most recent).
            var estimate: String?
            let years = Set(tiles.values.flatMap(\.nightsByYear.keys)).sorted(by: >)
            for year in years {
                let best = tiles.compactMap { key, tile -> (key: String, nights: Int, latest: Int32)? in
                    guard let nights = tile.nightsByYear[year], nights.count >= HomeBaseFinder.minimumDays else { return nil }
                    return (key, nights.count, nights.max() ?? .min)
                }.max { ($0.nights, $0.latest, $1.key) < ($1.nights, $1.latest, $0.key) }
                if let best {
                    estimate = best.key
                    break
                }
            }
            let ranked = tiles.sorted { ($0.value.days.count, $0.value.latest, $1.key) > ($1.value.days.count, $1.value.latest, $0.key) }.prefix(limit)
            let placeIDs = ranked.compactMap { $0.value.places.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
            var names: [Int64: String] = [:]
            if !placeIDs.isEmpty {
                let marks = Array(repeating: "?", count: placeIDs.count).joined(separator: ", ")
                for row in try Row.fetchAll(db, sql: "SELECT id, name FROM place WHERE id IN (\(marks))", arguments: StatementArguments(placeIDs)) {
                    names[row["id"]] = row["name"]
                }
            }
            return ranked.map { key, tile in
                let place = tile.places.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
                return HomeCandidate(tile: key, center: Coordinate(latitude: DayBuilder.median(tile.latitudes), longitude: DayBuilder.median(tile.longitudes)),
                                     name: place.flatMap { names[$0] }, nights: tile.days.count, isEstimate: key == estimate)
            }
        }
    }

    /// Every folded name variant of the places with at least `minPhotos` photos (the query parser's own place names).
    public func ownPlaceNames(minPhotos: Int = 1, limit: Int = 100_000) async throws -> Set<String> {
        try await database.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT n.name FROM place_name n JOIN place p ON p.id = n.place_id WHERE p.photo_count >= ? LIMIT ?
                """, arguments: [minPhotos, limit]))
        }
    }

    /// The index version (it bumps on every committed change readers should see).
    public func indexVersion() async throws -> Int64 {
        try await database.read { db in try Meta.int(db, .indexVersion) ?? 0 }
    }
}

enum PlaceQueries {
    /// The `place p` columns ``place(_:)`` reads.
    static let columns = "p.id, p.kind, p.key, p.name, p.category, p.lat, p.lon, p.radius_m, p.country_code, p.photo_count, p.last_utc, p.source"

    static func place(_ row: Row) -> PlaceRow {
        let lat: Double? = row["lat"], lon: Double? = row["lon"]
        return PlaceRow(id: row["id"], kind: PlaceKind(rawValue: row["kind"]) ?? .poi, key: row["key"], name: row["name"],
                        category: (row["category"] as String?).flatMap(PlaceCategory.init(rawValue:)),
                        center: lat.flatMap { lat in lon.map { Coordinate(latitude: lat, longitude: $0) } }, radius: row["radius_m"],
                        countryCode: row["country_code"], photoCount: row["photo_count"], lastUTC: row["last_utc"],
                        isFromAppleMaps: row["source"] == PlaceRowSource.appleMaps.rawValue)
    }

    /// The most names the typo pass compares.
    static let typoNameLimit = 10_000

    /// Places with photos whose name has, for every word, a word within one edit (words under 3 letters must be
    /// equal), most photographed first.
    static func typoMatches(_ db: Database, words: [String], limit: Int) throws -> [PlaceRow] {
        guard words.contains(where: { $0.count >= 3 }) else { return [] }
        let targets = words.map { Array($0.unicodeScalars) }
        var matched: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT n.place_id, n.name FROM place_name n JOIN place p ON p.id = n.place_id WHERE p.photo_count >= 1 ORDER BY p.photo_count DESC, n.id LIMIT ?
            """, arguments: [typoNameLimit]) {
            let id: Int64 = row["place_id"]
            guard matched[id] == nil else { continue }
            let name: String = row["name"]
            let nameWords = name.split(separator: " ").map { Array($0.unicodeScalars) }
            let fits = targets.allSatisfy { word in
                nameWords.contains { word.count >= 3 ? withinOneEdit(word, $0) : word == $0 }
            }
            if fits { matched[id] = name }
        }
        guard !matched.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: matched.count).joined(separator: ", ")
        return try Row.fetchAll(db, sql: "SELECT \(columns) FROM place p WHERE p.id IN (\(marks)) ORDER BY p.photo_count DESC, p.id LIMIT ?",
                                arguments: StatementArguments(Array(matched.keys)) + [limit]).map { row in
            var place = place(row)
            place.matchedName = matched[place.id]
            place.match = .typo
            return place
        }
    }

    /// Levenshtein distance ≤ 1: one substitution, insertion or deletion at most.
    static func withinOneEdit(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Bool {
        if abs(a.count - b.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if a.count < b.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    /// Distances from `c` of the rows whose position columns fall within `radius` (a bounding box in SQL, then
    /// the great-circle distance).
    static func distances(_ database: IndexDatabase, from c: Coordinate, within radius: Double, columns: (lat: String, lon: String)) async throws -> [Double] {
        let latitudeSpan = radius / 111_320
        let longitudeSpan = radius / (111_320 * max(0.01, cos(c.latitude * .pi / 180)))
        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(columns.lat) AS lat, \(columns.lon) AS lon FROM asset
                WHERE \(columns.lat) BETWEEN ? AND ? AND \(columns.lon) BETWEEN ? AND ?
                """, arguments: [c.latitude - latitudeSpan, c.latitude + latitudeSpan, c.longitude - longitudeSpan, c.longitude + longitudeSpan])
                .map { Coordinate(latitude: $0["lat"], longitude: $0["lon"]) }
        }
        return rows.map { $0.distance(to: c) }.filter { $0 <= radius }
    }
}
