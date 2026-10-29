import Foundation
import LZGeo
import LZLibrary
internal import GRDB

/// What one structure run needs from outside the day being rebuilt: home bases, saved places and trips. Loaded
/// once per run (they change only in a run's final steps, which come before or after the days).
struct DayContext: Sendable {
    struct Area: Sendable, Hashable {
        var placeID: Int64
        var center: Coordinate
        var radius: Double
    }

    struct TripSpan: Sendable, Hashable {
        var id: Int64
        var days: ClosedRange<Int32>
    }

    /// The home base's point per local year.
    var homes: [Int: Coordinate]
    /// The `home` place row (kind 7), when there is a home.
    var homePlace: Int64?
    /// Saved places (kind 6), with their radius.
    var saved: [Area]
    var trips: [TripSpan]

    static let homeRadius: Double = 150

    static func load(_ db: Database) throws -> DayContext {
        var homes: [Int: Coordinate] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT year, lat, lon FROM home_base") {
            homes[row["year"]] = Coordinate(latitude: row["lat"], longitude: row["lon"])
        }
        let homePlace = try Int64.fetchOne(db, sql: "SELECT id FROM place WHERE key = 'home'")
        let saved = try Row.fetchAll(db, sql: "SELECT id, lat, lon, radius_m FROM place WHERE kind = ? AND lat IS NOT NULL AND radius_m IS NOT NULL",
                                     arguments: [PlaceKind.saved.rawValue]).map { row in
            Area(placeID: row["id"], center: Coordinate(latitude: row["lat"], longitude: row["lon"]), radius: row["radius_m"])
        }
        let trips = try Row.fetchAll(db, sql: "SELECT id, start_day, end_day FROM trip").map { row in
            TripSpan(id: row["id"], days: (row["start_day"] as Int32)...(row["end_day"] as Int32))
        }
        return DayContext(homes: homes, homePlace: homePlace, saved: saved, trips: trips)
    }
}

/// The five place columns of an asset.
struct PlaceColumns: Sendable, Hashable {
    var city: Int64?
    var metro: Int64?
    var locality: Int64?
    var region: Int64?
    var country: Int64?
}

/// Rebuilds one moment day exactly (search spec §4.2–4.3), inside the caller's write transaction:
/// 1. **Placement.** Each located asset gets its cell's gazetteer places, with Apple Maps' locality where the
///    gazetteer has no city, and Apple's country where the gazetteer isn't confident.
/// 2. **Moments.** ``MomentSegmenter`` splits the day (90 min gap, 1 km jump).
/// 3. **Borrowing.** An asset without GPS takes the position and places of the located asset of its moment
///    nearest in time: within 10 min `place_src` 2, within 2 h `place_src` 3, beyond that none.
/// 4. **Rows.** Moments are diffed with the day's existing ones by (first asset, item count): unchanged ones keep
///    their id and are updated only where a value differs, so moment ids stay stable when only labels change.
///    Each gets its counts, median centre, p90 spread, dominant cell, cover and label.
///
/// Label rule, first that applies: a saved place or the home containing the centre; the dominant cell's Apple
/// Maps area if it covers ≥ 40% of the located items; the dominant locality, unless the centre is nearer the
/// city's own point than the locality's (the gazetteer's locality is the nearest other place, which near a city
/// centre is often a neighbouring district); the city; the country. Region names are never labels.
struct DayBuilder {
    let db: Database
    let geo: GeoCache
    let context: DayContext
    private var places: PlaceRows
    private var areas: [Int64: DayContext.Area?] = [:]
    private var points: [Int64: Coordinate?] = [:]
    /// Rows written (assets and moments).
    private(set) var changes = 0

    static let nearBorrow: Int64 = 10 * 60
    static let farBorrow: Int64 = 2 * 3_600
    static let poiShare = 0.4

    init(_ db: Database, geo: GeoCache, context: DayContext) {
        self.db = db
        self.geo = geo
        self.context = context
        places = PlaceRows(db)
    }

    /// One asset of the day, with its current derived values.
    private struct Item {
        var id: Int64
        var utc: Int64
        var wall: Int64
        var zone: Int64?
        var isVideo: Bool
        var flags: AssetFlags
        var isScreenshot: Bool
        var coordinate: Coordinate?
        var cell: String?
        var placeSource: Int
        var effective: Coordinate?
        var places: PlaceColumns
        var moment: Int64?

        init(_ row: Row) {
            id = row["id"]
            utc = row["created_utc"]
            wall = row["wall_s"]
            zone = row["tz"]
            isVideo = row["kind"] == 1
            flags = AssetFlags(rawValue: row["flags"])
            isScreenshot = (row["subtypes"] as Int) & AssetFacts.Subtypes.screenshot.rawValue != 0
            if let lat = row["lat"] as Double?, let lon = row["lon"] as Double? { coordinate = Coordinate(latitude: lat, longitude: lon) }
            cell = row["cell"]
            placeSource = row["place_src"]
            if let lat = row["eff_lat"] as Double?, let lon = row["eff_lon"] as Double? { effective = Coordinate(latitude: lat, longitude: lon) }
            places = PlaceColumns(city: row["city_place"], metro: row["metro_place"], locality: row["locality_place"], region: row["region_place"],
                                  country: row["country_place"])
            moment = row["moment_id"]
        }
    }

    /// What P2 found for a cell.
    private struct CellNames {
        var appleLocality: String?
        var appleCountry: String?
        var poiPlace: Int64?
    }

    /// A moment's columns except its id.
    private struct MomentValues: Hashable {
        var day: Int32
        var startUTC: Int64
        var endUTC: Int64
        var startWall: Int64
        var endWall: Int64
        var zone: Int64?
        var firstAsset: Int64
        var items: Int
        var photos: Int
        var videos: Int
        var located: Int
        var borrowed: Int
        var center: Coordinate?
        var spread: Double?
        var cell: String?
        var label: Int64?
        var city: Int64?
        var country: Int64?
        var trip: Int64?
        var cover: Int64?

        init(_ row: Row) {
            day = row["day"]
            startUTC = row["start_utc"]
            endUTC = row["end_utc"]
            startWall = row["start_wall"]
            endWall = row["end_wall"]
            zone = row["tz"]
            firstAsset = row["first_asset"]
            items = row["item_count"]
            photos = row["photo_count"]
            videos = row["video_count"]
            located = row["located_count"]
            borrowed = row["borrowed_count"]
            if let lat = row["lat"] as Double?, let lon = row["lon"] as Double? { center = Coordinate(latitude: lat, longitude: lon) }
            spread = row["spread_m"]
            cell = row["cell"]
            label = row["label_place"]
            city = row["city_place"]
            country = row["country_place"]
            trip = row["trip_id"]
            cover = row["cover_asset"]
        }

        init(day: Int32, firstAsset: Int64, startUTC: Int64) {
            self.day = day
            self.firstAsset = firstAsset
            self.startUTC = startUTC
            endUTC = startUTC
            startWall = 0
            endWall = 0
            items = 0
            photos = 0
            videos = 0
            located = 0
            borrowed = 0
        }

        var arguments: [(any DatabaseValueConvertible)?] {
            [day, startUTC, endUTC, startWall, endWall, zone, firstAsset, items, photos, videos, located, borrowed, center?.latitude, center?.longitude,
             spread, cell, label, city, country, trip, cover]
        }

        static let columns = """
            day, start_utc, end_utc, start_wall, end_wall, tz, first_asset, item_count, photo_count, video_count, located_count, borrowed_count,
            lat, lon, spread_m, cell, label_place, city_place, country_place, trip_id, cover_asset
            """
        private static let names = columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        static let insertSQL = "INSERT INTO moment (\(columns)) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))"
        static let updateSQL = "UPDATE moment SET \(names.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?"
    }

    // MARK: Rebuild

    /// Rebuilds `day` and removes it from `dirty_day`.
    mutating func rebuild(day: Int32) throws {
        var items = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT id, created_utc, wall_s, tz, kind, flags, subtypes, lat, lon, cell, place_src, eff_lat, eff_lon,
                   city_place, metro_place, locality_place, region_place, country_place, moment_id
            FROM asset WHERE day = ? AND created_utc IS NOT NULL AND wall_s IS NOT NULL ORDER BY created_utc, id
            """), arguments: [day]).map(Item.init)
        let names = try cellNames(Set(items.compactMap(\.cell)))
        var placed: [String: PlaceColumns] = [:]
        for hash in Set(items.compactMap(\.cell)) { placed[hash] = try placement(hash, names[hash]) }

        let starts = [0] + MomentSegmenter.boundaries(items.map { MomentSegmenter.Item(utc: $0.utc, day: day, coordinate: $0.coordinate) }).map(\.index)
        let segments = items.isEmpty ? [] : zip(starts, starts.dropFirst() + [items.count]).map { $0..<$1 }

        // Target place columns per item: own GPS, or borrowed from the moment's nearest located item.
        var targets: [(source: PlaceSource, effective: Coordinate?, places: PlaceColumns)] = items.map { item in
            guard let coordinate = item.coordinate, let cell = item.cell else { return (.none, nil, PlaceColumns()) }
            return (.gps, coordinate, placed[cell] ?? PlaceColumns())
        }
        for segment in segments {
            let located = segment.filter { items[$0].coordinate != nil }
            guard !located.isEmpty else { continue }
            for index in segment where items[index].coordinate == nil {
                // Nearest in time; the earlier one on a tie (located is in time order).
                let source = located.min { abs(items[$0].utc - items[index].utc) < abs(items[$1].utc - items[index].utc) }!
                let gap = abs(items[source].utc - items[index].utc)
                guard gap <= Self.farBorrow else { continue }
                targets[index] = (gap <= Self.nearBorrow ? .momentNear : .momentFar, targets[source].effective, targets[source].places)
            }
        }

        // Moments: keep the id of every segment that starts with the same asset and holds as many items.
        let existing = try Row.fetchAll(db.cachedStatement(sql: "SELECT * FROM moment WHERE day = ?"), arguments: [day]).map { (id: $0["id"] as Int64, values: MomentValues($0)) }
        var unmatched = Dictionary(existing.map { ("\($0.values.firstAsset):\($0.values.items)", $0) }, uniquingKeysWith: { first, _ in first })
        var momentIDs: [Int64?] = Array(repeating: nil, count: segments.count)
        var values: [MomentValues] = []
        var updates: [(id: Int64, old: MomentValues, new: MomentValues)] = []
        for (index, segment) in segments.enumerated() {
            var value = try moment(day: day, items: segment.map { (items[$0], targets[$0]) }, names: names)
            // Two moments can start in the same second (photos from two cameras in a shared library): the key
            // (day, start) stays unique by starting the later one a second later.
            if let previous = values.last, value.startUTC <= previous.startUTC { value.startUTC = previous.startUTC + 1 }
            values.append(value)
            if let match = unmatched.removeValue(forKey: "\(value.firstAsset):\(value.items)") {
                momentIDs[index] = match.id
                if match.values != value { updates.append((match.id, match.values, value)) }
            }
        }
        // Written in an order the unique (day, start) key allows: the unmatched rows go first; when several kept rows
        // change their start, they step aside to a start no photo has before any takes its new one; new rows go last.
        if !unmatched.isEmpty {
            let ids = unmatched.values.map(\.id)
            try db.execute(sql: "DELETE FROM moment WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))", arguments: StatementArguments(ids))
            changes += ids.count
        }
        let moving = updates.filter { $0.old.startUTC != $0.new.startUTC }
        if moving.count > 1 {
            let aside = try db.cachedStatement(sql: "UPDATE moment SET start_utc = ? WHERE id = ?")
            for update in moving { try aside.execute(arguments: [Int64.min + update.id, update.id]) }
        }
        for update in updates {
            try db.cachedStatement(sql: MomentValues.updateSQL).execute(arguments: StatementArguments(update.new.arguments + [update.id]))
            changes += 1
        }
        for index in segments.indices where momentIDs[index] == nil {
            try db.cachedStatement(sql: MomentValues.insertSQL).execute(arguments: StatementArguments(values[index].arguments))
            momentIDs[index] = db.lastInsertedRowID
            changes += 1
        }

        // Assets: write only what changed.
        let update = try db.cachedStatement(sql: """
            UPDATE asset SET place_src = ?, eff_lat = ?, eff_lon = ?, city_place = ?, metro_place = ?, locality_place = ?, region_place = ?,
                             country_place = ?, moment_id = ? WHERE id = ?
            """)
        for (segmentIndex, segment) in segments.enumerated() {
            for index in segment {
                let item = items[index], target = targets[index], moment = momentIDs[segmentIndex]
                guard item.placeSource != target.source.rawValue || item.effective != target.effective || item.places != target.places
                    || item.moment != moment else { continue }
                try update.execute(arguments: [target.source.rawValue, target.effective?.latitude, target.effective?.longitude, target.places.city,
                                               target.places.metro, target.places.locality, target.places.region, target.places.country, moment,
                                               item.id])
                items[index].moment = moment
                changes += 1
            }
        }
        try db.cachedStatement(sql: "DELETE FROM dirty_day WHERE day = ?").execute(arguments: [day])
    }

    /// Places the located assets that have no moment day (undated ones): their cell's places, as for dated ones.
    mutating func placeUndated() throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, cell, city_place, metro_place, locality_place, region_place, country_place FROM asset WHERE day IS NULL AND cell IS NOT NULL
            """)
        guard !rows.isEmpty else { return }
        let cells = Set(rows.map { $0["cell"] as String })
        let names = try cellNames(cells)
        var placed: [String: PlaceColumns] = [:]
        for hash in cells { placed[hash] = try placement(hash, names[hash]) }
        let update = try db.cachedStatement(sql: """
            UPDATE asset SET city_place = ?, metro_place = ?, locality_place = ?, region_place = ?, country_place = ? WHERE id = ?
            """)
        for row in rows {
            let target = placed[row["cell"]] ?? PlaceColumns()
            let current = PlaceColumns(city: row["city_place"], metro: row["metro_place"], locality: row["locality_place"], region: row["region_place"],
                                       country: row["country_place"])
            guard current != target else { continue }
            try update.execute(arguments: [target.city, target.metro, target.locality, target.region, target.country, row["id"]])
            changes += 1
        }
    }

    // MARK: Moment values

    private mutating func moment(day: Int32, items: [(item: Item, target: (source: PlaceSource, effective: Coordinate?, places: PlaceColumns))],
                                 names: [String: CellNames]) throws -> MomentValues {
        let first = items[0].item, last = items[items.count - 1].item
        var value = MomentValues(day: day, firstAsset: first.id, startUTC: first.utc)
        value.endUTC = last.utc
        value.startWall = first.wall
        value.endWall = last.wall
        value.zone = first.zone
        value.items = items.count
        value.videos = items.filter(\.item.isVideo).count
        value.photos = items.count - value.videos
        let located = items.filter { $0.item.coordinate != nil }
        value.located = located.count
        value.borrowed = items.filter { $0.target.source == .momentNear || $0.target.source == .momentFar }.count
        value.trip = context.trips.first { $0.days.contains(day) }?.id

        // Cover: the first favourite, else the middle photo that isn't a screenshot, else the middle item.
        let photos = items.filter { !$0.item.isVideo && !$0.item.isScreenshot }
        value.cover = (items.first { $0.item.flags.contains(.favorite) } ?? (photos.isEmpty ? items[items.count / 2] : photos[photos.count / 2])).item.id

        guard !located.isEmpty else { return value }
        let coordinates = located.compactMap(\.item.coordinate)
        let center = Coordinate(latitude: Self.median(coordinates.map(\.latitude)), longitude: Self.median(coordinates.map(\.longitude)))
        value.center = center
        let distances = coordinates.map { $0.distance(to: center) }.sorted()
        value.spread = distances[min(distances.count - 1, Int((Double(distances.count) * 0.9).rounded(.up)) - 1)]
        value.cell = Self.dominant(located.compactMap(\.item.cell))
        value.city = Self.dominant(located.compactMap(\.target.places.city))
        value.country = Self.dominant(located.compactMap(\.target.places.country))
        value.label = try label(day: day, center: center, coordinates: coordinates, cell: value.cell, names: names,
                                localities: located.compactMap(\.target.places.locality), city: value.city, country: value.country)
        return value
    }

    private mutating func label(day: Int32, center: Coordinate, coordinates: [Coordinate], cell: String?, names: [String: CellNames],
                                localities: [Int64], city: Int64?, country: Int64?) throws -> Int64? {
        let saved = context.saved.filter { center.distance(to: $0.center) <= $0.radius }
            .min { center.distance(to: $0.center) / $0.radius < center.distance(to: $1.center) / $1.radius }
        if let saved { return saved.placeID }
        if let home = context.homes[day.civilYear], let place = context.homePlace, center.distance(to: home) <= DayContext.homeRadius { return place }
        if let cell, let poi = names[cell]?.poiPlace, let area = try area(poi) {
            let inside = coordinates.filter { $0.distance(to: area.center) <= area.radius }.count
            if Double(inside) >= Self.poiShare * Double(coordinates.count) { return poi }
        }
        if let locality = Self.dominant(localities), try !isNearerCity(than: locality, city: city, to: center) { return locality }
        return city ?? country
    }

    /// Whether `center` is nearer the city's point than the locality's. Apple Maps localities have no point and
    /// are kept.
    private mutating func isNearerCity(than locality: Int64, city: Int64?, to center: Coordinate) throws -> Bool {
        guard let city, city != locality, let cityPoint = try point(city), let localityPoint = try point(locality) else { return false }
        return center.distance(to: cityPoint) < center.distance(to: localityPoint)
    }

    // MARK: Places

    /// The gazetteer's places for a cell, with what Apple Maps said about it.
    private mutating func placement(_ hash: String, _ names: CellNames?) throws -> PlaceColumns {
        let cell = geo.cell(hash)
        func id(_ key: String?, asLocality: Bool = false) throws -> Int64? {
            guard let key, var spec = geo.place(key) else { return nil }
            if asLocality { spec.kind = .locality }
            return try places.id(spec)
        }
        var columns = PlaceColumns(city: try id(cell.city), metro: try id(cell.metro), locality: try id(cell.locality, asLocality: true),
                                   region: try id(cell.region), country: try id(cell.country))
        if let names {
            if let locality = names.appleLocality, !locality.isEmpty {
                let countryCode = names.appleCountry ?? cell.country.flatMap { geo.place($0)?.countryCode }
                columns.locality = try places.id(PlaceSpec(appleLocality: locality, countryCode: countryCode))
            }
            if let country = names.appleCountry, !cell.countryConfident { columns.country = try places.id(PlaceSpec(country: country)) }
        }
        return columns
    }

    private func cellNames(_ cells: Set<String>) throws -> [String: CellNames] {
        guard !cells.isEmpty else { return [:] }
        let list = Array(cells)
        var names: [String: CellNames] = [:]
        for start in stride(from: 0, to: list.count, by: 900) {
            let chunk = list[start..<min(list.count, start + 900)]
            for row in try Row.fetchAll(db, sql: """
                SELECT cell, apple_locality, apple_country, poi_place FROM cell
                WHERE cell IN (\(chunk.map { _ in "?" }.joined(separator: ", "))) AND (apple_locality IS NOT NULL OR apple_country IS NOT NULL OR poi_place IS NOT NULL)
                """, arguments: StatementArguments(Array(chunk))) {
                names[row["cell"]] = CellNames(appleLocality: row["apple_locality"], appleCountry: row["apple_country"], poiPlace: row["poi_place"])
            }
        }
        return names
    }

    /// An Apple Maps area's centre and radius.
    private mutating func area(_ placeID: Int64) throws -> DayContext.Area? {
        if let cached = areas[placeID] { return cached }
        let area = try Row.fetchOne(db, sql: "SELECT lat, lon, radius_m FROM place WHERE id = ? AND lat IS NOT NULL AND radius_m IS NOT NULL",
                                    arguments: [placeID]).map { row in
            DayContext.Area(placeID: placeID, center: Coordinate(latitude: row["lat"], longitude: row["lon"]), radius: row["radius_m"])
        }
        areas[placeID] = .some(area)
        return area
    }

    /// A place's point, when it has one.
    private mutating func point(_ placeID: Int64) throws -> Coordinate? {
        if let cached = points[placeID] { return cached }
        let point = try Row.fetchOne(db, sql: "SELECT lat, lon FROM place WHERE id = ? AND lat IS NOT NULL AND lon IS NOT NULL",
                                     arguments: [placeID]).map { Coordinate(latitude: $0["lat"], longitude: $0["lon"]) }
        points[placeID] = .some(point)
        return point
    }

    // MARK: Helpers

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The most frequent value; a tie goes to the one seen first.
    static func dominant<T: Hashable>(_ values: [T]) -> T? {
        var counts: [T: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        var best: (value: T, count: Int)?
        for value in values where counts[value]! > (best?.count ?? 0) { best = (value, counts[value]!) }
        return best?.value
    }
}
