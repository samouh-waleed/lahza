import Foundation
import LZGeo
internal import GRDB

/// Read-only queries over the index. Each call is one database read, so it sees one consistent snapshot even
/// while a sync writes.
public struct IndexReader: Sendable {
    /// Which index session the reader belongs to (it changes when the index is purged or rebuilt).
    public let generation: Int
    let database: IndexDatabase
    private let snapshots: SnapshotStore

    init(database: IndexDatabase, generation: Int = 0) {
        self.database = database
        self.generation = generation
        snapshots = SnapshotStore()
    }

    /// The assets as in-memory columns for search, for the current index version (shared by the session's readers,
    /// rebuilt at most once a second while versions churn).
    public func snapshot() async throws -> SearchSnapshot {
        let database = database, generation = generation
        let version = try await indexVersion()
        return try await snapshots.snapshot(version: version) {
            try await database.read { db in try IndexQueries.snapshot(db, generation: generation) }
        }
    }

    /// Drops the snapshot (a memory warning); the next search builds it again.
    public func releaseSnapshot() async {
        await snapshots.release()
    }

    public func summary() async throws -> LibrarySummary {
        try await database.read(IndexQueries.summary)
    }

    /// `PHAsset.localIdentifier`s for asset row ids (missing ids are left out).
    public func localIdentifiers(for assetIDs: [Int64]) async throws -> [Int64: String] {
        try await database.read { db in
            var identifiers: [Int64: String] = [:]
            for start in stride(from: 0, to: assetIDs.count, by: 900) {
                let chunk = assetIDs[start..<min(assetIDs.count, start + 900)]
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                for row in try Row.fetchAll(db, sql: "SELECT id, local_id FROM asset WHERE id IN (\(marks))", arguments: StatementArguments(chunk)) {
                    identifiers[row["id"]] = row["local_id"]
                }
            }
            return identifiers
        }
    }

    /// Moments newest first: the page after `key` (from the start when nil), at most `limit`.
    public func moments(after key: MomentKey?, limit: Int, filter: MomentFilter = .all) async throws -> [MomentRow] {
        try await database.read { db in
            var conditions: [String] = []
            var arguments: [(any DatabaseValueConvertible)?] = []
            if let key {
                conditions.append("(m.day, m.start_utc) < (?, ?)")
                arguments += [key.day, key.startUTC]
            }
            if let year = filter.year {
                conditions.append("m.day >= ? AND m.day < ?")
                arguments += [LocalTime.day(year: year, month: 1, day: 1), LocalTime.day(year: year + 1, month: 1, day: 1)]
            }
            if let trip = filter.tripID {
                conditions.append("m.trip_id = ?")
                arguments.append(trip)
            }
            let condition = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            arguments.append(max(0, limit))
            let rows = try Row.fetchAll(db, sql: "\(IndexQueries.momentSelect) \(condition) ORDER BY m.day DESC, m.start_utc DESC LIMIT ?",
                                        arguments: StatementArguments(arguments)).map(IndexQueries.momentRow)
            return try IndexQueries.withThumbnails(db, rows)
        }
    }

    /// Moments by row id (search hits), newest first.
    public func momentRows(ids: [Int64]) async throws -> [MomentRow] {
        try await database.read { db in
            var rows: [MomentRow] = []
            for start in stride(from: 0, to: ids.count, by: 900) {
                let chunk = ids[start..<min(ids.count, start + 900)]
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                rows += try Row.fetchAll(db, sql: "\(IndexQueries.momentSelect) WHERE m.id IN (\(marks))", arguments: StatementArguments(chunk))
                    .map(IndexQueries.momentRow)
            }
            return try IndexQueries.withThumbnails(db, rows.sorted { ($0.key.day, $0.key.startUTC) > ($1.key.day, $1.key.startUTC) })
        }
    }

    /// One moment and its items in time order; nil when no moment has that key (any more).
    public func moment(_ key: MomentKey) async throws -> MomentDetailRows? {
        try await database.read { db in
            guard let row = try Row.fetchOne(db, sql: "\(IndexQueries.momentSelect) WHERE m.day = ? AND m.start_utc = ?",
                                             arguments: [key.day, key.startUTC]).map(IndexQueries.momentRow),
                  let moment = try IndexQueries.withThumbnails(db, [row]).first else { return nil }
            let members = try Row.fetchAll(db, sql: """
                SELECT id, local_id, kind, created_utc, wall_s, duration, flags, place_src FROM asset WHERE moment_id = ? ORDER BY created_utc, id
                """, arguments: [moment.id]).map { row in
                MomentDetailRows.Member(id: row["id"], localID: row["local_id"], isVideo: row["kind"] == 1, utc: row["created_utc"], wall: row["wall_s"],
                                        duration: row["duration"], isFavorite: (row["flags"] as Int) & AssetFlags.favorite.rawValue != 0,
                                        hasBorrowedLocation: (row["place_src"] as Int) >= PlaceSource.momentNear.rawValue)
            }
            return MomentDetailRows(moment: moment, members: members)
        }
    }

    /// Trips newest first, with the places they visit and their mosaic.
    public func trips() async throws -> [TripRow] {
        try await database.read { db in
            let trips = try Row.fetchAll(db, sql: """
                SELECT t.id, t.start_day, t.end_day, t.label, country.country_code AS country, t.abroad, t.moment_count, t.item_count,
                       t.video_count, t.max_km, cover.local_id AS cover
                FROM trip t LEFT JOIN place country ON country.id = t.country_place LEFT JOIN asset cover ON cover.id = t.cover_asset
                ORDER BY t.start_day DESC
                """).map { row in
                TripRow(id: row["id"], startDay: row["start_day"], endDay: row["end_day"], label: row["label"], countryCode: row["country"],
                        abroad: row["abroad"], momentCount: row["moment_count"], itemCount: row["item_count"], videoCount: row["video_count"],
                        maxKm: row["max_km"], coverLocalID: row["cover"])
            }
            return try IndexQueries.withPlacesAndMosaics(db, trips)
        }
    }

    /// The home base of a local year, or the latest one when `year` is nil.
    public func homeBase(year: Int?) async throws -> HomeBaseRow? {
        try await database.read { db in
            let condition = year == nil ? "" : "WHERE h.year = ?"
            let arguments: StatementArguments = year.map { [$0] } ?? []
            return try Row.fetchOne(db, sql: """
                SELECT h.year, h.lat, h.lon, h.tile, zone.name AS zone, h.country_code, h.nights, h.source
                FROM home_base h LEFT JOIN zone ON zone.id = h.tz \(condition) ORDER BY h.year DESC LIMIT 1
                """, arguments: arguments).map { row in
                HomeBaseRow(year: row["year"], center: Coordinate(latitude: row["lat"], longitude: row["lon"]), tile: row["tile"],
                            timeZone: row["zone"], countryCode: row["country_code"], nights: row["nights"],
                            source: HomeBaseRow.Source(rawValue: row["source"]) ?? .estimated)
            }
        }
    }

    /// Moments per local month, newest first (the Moments tab's year strip and month headers).
    public func momentMonths() async throws -> [MonthCount] {
        try await database.read { db in
            var months: [Int: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT day, COUNT(*) AS moments FROM moment GROUP BY day") {
                let date = LocalTime.civil(day: row["day"])
                months[date.year * 100 + date.month, default: 0] += row["moments"] as Int
            }
            return months.sorted { $0.key > $1.key }.map { MonthCount(year: $0.key / 100, month: $0.key % 100, moments: $0.value) }
        }
    }

    /// The index file's size (SQLite's page counters).
    public func sizeBytes() async throws -> Int64 {
        try await database.sizeBytes()
    }

    /// The DEBUG index inspector's data: sync state, versions, row counts and the structure at a glance.
    /// Never the change token's bytes, coordinates or local identifiers.
    public func inspector() async throws -> IndexInspectorData {
        try await database.read(IndexQueries.inspector)
    }
}

/// What the DEBUG index inspector shows (aggregates and names only).
public struct IndexInspectorData: Sendable, Hashable {
    public struct Table: Sendable, Hashable {
        public var name: String
        public var rows: Int
    }

    public struct HomeBase: Sendable, Hashable {
        public var year: Int
        public var nights: Int
        /// 0 estimated, 1 inherited, 2 user.
        public var source: Int
        public var countryCode: String?
        public var timeZone: String?
    }

    public struct Trip: Sendable, Hashable {
        public var startDay: Int32
        public var endDay: Int32
        public var label: String
        public var items: Int
        public var abroad: Bool
    }

    public struct Place: Sendable, Hashable {
        /// 1 country, 2 region, 3 city, 4 locality, 5 POI, 6 saved, 7 home, 8 map result.
        public var kind: Int
        public var name: String
        public var photos: Int
        /// 1 gazetteer, 2 Apple Maps, 3 user, 4 inferred.
        public var source: Int
    }

    /// `idle`, `dated`, `undated` or `catchup`.
    public var scanPhase: String
    public var scanReason: String?
    public var hasChangeToken: Bool
    public var scanGeneration: Int64
    public var scanFrontier: Date?
    public var scanDone: Int
    public var scanTotal: Int
    public var accessScope: String?
    public var firstBuildDone: Bool
    public var structureVersion: Int64?
    public var gazetteerVersion: Int64?
    public var indexVersion: Int64
    public var deviceTimeZone: String?
    public var lastSync: Date?
    public var lastFullScan: Date?
    public var mapsBackoffUntil: Date?
    public var tables: [Table]
    /// Cells per Apple Maps naming status (`cell.poi_status`).
    public var placeNameStatus: [Int: Int]
    public var homeBases: [HomeBase]
    public var trips: [Trip]
    /// The 50 places with the most photos.
    public var topPlaces: [Place]
}

/// The queries behind ``IndexReader``, usable inside any read or write.
enum IndexQueries {
    /// A moment row with its zone, label, city, country and cover; callers add WHERE and ORDER BY.
    static let momentSelect = """
        SELECT m.id, m.day, m.start_utc, m.end_utc, m.start_wall, m.end_wall, zone.name AS zone, m.item_count, m.photo_count,
               m.video_count, m.located_count, m.borrowed_count, label.name AS label, city.name AS city, country.country_code AS country,
               m.trip_id, cover.local_id AS cover, m.cell
        FROM moment m
        LEFT JOIN zone ON zone.id = m.tz
        LEFT JOIN place label ON label.id = m.label_place
        LEFT JOIN place city ON city.id = m.city_place
        LEFT JOIN place country ON country.id = m.country_place
        LEFT JOIN asset cover ON cover.id = m.cover_asset
        """

    static func momentRow(_ row: Row) -> MomentRow {
        MomentRow(id: row["id"], key: MomentKey(day: row["day"], startUTC: row["start_utc"]), endUTC: row["end_utc"], startWall: row["start_wall"],
                  endWall: row["end_wall"], timeZone: row["zone"], itemCount: row["item_count"], photoCount: row["photo_count"],
                  videoCount: row["video_count"], locatedCount: row["located_count"], borrowedCount: row["borrowed_count"], label: row["label"],
                  cityName: row["city"], countryCode: row["country"], tripID: row["trip_id"], coverLocalID: row["cover"], cell: row["cell"])
    }

    /// Fills each moment's thumbnails: its cover, then its other items in time order, at most `perMoment`.
    static func withThumbnails(_ db: Database, _ rows: [MomentRow], perMoment: Int = 3) throws -> [MomentRow] {
        guard !rows.isEmpty else { return rows }
        var thumbnails: [Int64: [String]] = [:]
        let ids = rows.map(\.id)
        for start in stride(from: 0, to: ids.count, by: 900) {
            let chunk = ids[start..<min(ids.count, start + 900)]
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: """
                SELECT moment_id, local_id FROM (
                  SELECT a.moment_id, a.local_id,
                         ROW_NUMBER() OVER (PARTITION BY a.moment_id ORDER BY a.id = m.cover_asset DESC, a.created_utc, a.id) AS rank
                  FROM asset a JOIN moment m ON m.id = a.moment_id WHERE a.moment_id IN (\(marks)))
                WHERE rank <= \(max(1, perMoment)) ORDER BY moment_id, rank
                """, arguments: StatementArguments(chunk)) {
                thumbnails[row["moment_id"], default: []].append(row["local_id"])
            }
        }
        return rows.map { row in
            var row = row
            row.thumbnailLocalIDs = thumbnails[row.id] ?? []
            return row
        }
    }

    /// Fills each trip's places (the city of each moment, or its town where there is no city, in visiting order,
    /// leaving out the trip's label) and its mosaic (the trip's cover, then the covers of its largest moments in
    /// time order, at most `mosaic`).
    static func withPlacesAndMosaics(_ db: Database, _ trips: [TripRow], mosaic: Int = 5) throws -> [TripRow] {
        guard !trips.isEmpty else { return trips }
        var places: [Int64: [String]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT m.trip_id, COALESCE(city.name, CASE WHEN label.kind = \(PlaceKind.locality.rawValue) THEN label.name END) AS place_name,
                   MIN(m.start_utc) AS first_utc
            FROM moment m LEFT JOIN place city ON city.id = m.city_place LEFT JOIN place label ON label.id = m.label_place
            WHERE m.trip_id IS NOT NULL GROUP BY m.trip_id, place_name HAVING place_name IS NOT NULL ORDER BY m.trip_id, first_utc
            """) {
            places[row["trip_id"], default: []].append(row["place_name"])
        }
        var covers: [Int64: [String]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT trip_id, local_id FROM (
              SELECT m.trip_id, cover.local_id, m.start_utc, ROW_NUMBER() OVER (PARTITION BY m.trip_id ORDER BY m.item_count DESC, m.start_utc) AS rank
              FROM moment m JOIN asset cover ON cover.id = m.cover_asset WHERE m.trip_id IS NOT NULL)
            WHERE rank <= \(max(1, mosaic)) ORDER BY trip_id, start_utc
            """) {
            covers[row["trip_id"], default: []].append(row["local_id"])
        }
        return trips.map { trip in
            var trip = trip
            trip.places = (places[trip.id] ?? []).filter { $0 != trip.label }
            let cover = trip.coverLocalID.map { [$0] } ?? []
            trip.thumbnailLocalIDs = Array((cover + (covers[trip.id] ?? []).filter { $0 != trip.coverLocalID }).prefix(max(1, mosaic)))
            return trip
        }
    }

    static func summary(_ db: Database) throws -> LibrarySummary {
        var summary = LibrarySummary()
        // Unreliable dates (none, before 2000, in the future) don't stretch the year range.
        let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS assets, TOTAL(kind = 0) AS photos, TOTAL(kind = 1) AS videos, TOTAL(lat IS NOT NULL) AS located,
                   COUNT(DISTINCT country_place) AS countries,
                   MIN(CASE WHEN flags & 32 = 0 THEN day END) AS first_day, MAX(CASE WHEN flags & 32 = 0 THEN day END) AS last_day
            FROM asset
            """)
        if let row {
            summary.assets = row["assets"]
            summary.photos = Int(row["photos"] as Double)
            summary.videos = Int(row["videos"] as Double)
            summary.located = Int(row["located"] as Double)
            summary.countries = row["countries"]
            summary.firstYear = (row["first_day"] as Int32?).map { LocalTime.civil(day: $0).year }
            summary.lastYear = (row["last_day"] as Int32?).map { LocalTime.civil(day: $0).year }
        }
        summary.moments = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM moment") ?? 0
        summary.trips = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trip") ?? 0
        // The city most of the latest home base's tile is placed in.
        summary.homeCityName = try String.fetchOne(db, sql: """
            SELECT place.name FROM place
            JOIN (SELECT city_place, COUNT(*) AS photos FROM asset
                  WHERE city_place IS NOT NULL AND substr(cell, 1, 6) = (SELECT tile FROM home_base ORDER BY year DESC LIMIT 1)
                  GROUP BY city_place ORDER BY photos DESC LIMIT 1) AS home ON home.city_place = place.id
            """)
        return summary
    }

    static func inspector(_ db: Database) throws -> IndexInspectorData {
        let state = try SyncState(db)
        let tables = try IndexSchema.tables.map { table in
            IndexInspectorData.Table(name: table, rows: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0)
        }
        var status: [Int: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT poi_status, COUNT(*) AS cells FROM cell GROUP BY poi_status") {
            status[row["poi_status"]] = row["cells"]
        }
        let homeBases = try Row.fetchAll(db, sql: """
            SELECT year, nights, source, country_code, zone.name AS zone FROM home_base LEFT JOIN zone ON zone.id = home_base.tz ORDER BY year
            """).map { row in
            IndexInspectorData.HomeBase(year: row["year"], nights: row["nights"], source: row["source"], countryCode: row["country_code"],
                                        timeZone: row["zone"])
        }
        let trips = try Row.fetchAll(db, sql: "SELECT start_day, end_day, label, item_count, abroad FROM trip ORDER BY start_day DESC").map { row in
            IndexInspectorData.Trip(startDay: row["start_day"], endDay: row["end_day"], label: row["label"], items: row["item_count"],
                                    abroad: row["abroad"])
        }
        let places = try Row.fetchAll(db, sql: "SELECT kind, name, photo_count, source FROM place ORDER BY photo_count DESC, id LIMIT 50").map { row in
            IndexInspectorData.Place(kind: row["kind"], name: row["name"], photos: row["photo_count"], source: row["source"])
        }
        return IndexInspectorData(
            scanPhase: state.phase.rawValue, scanReason: try Meta.string(db, .scanReason), hasChangeToken: state.libraryToken != nil,
            scanGeneration: state.generation, scanFrontier: state.frontier.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            scanDone: state.done, scanTotal: state.total, accessScope: state.accessScope, firstBuildDone: state.firstBuildDone,
            structureVersion: try Meta.int(db, .structureVersion), gazetteerVersion: try Meta.int(db, .gazetteerVersion),
            indexVersion: state.version, deviceTimeZone: try Meta.string(db, .deviceTimeZone), lastSync: state.lastSync,
            lastFullScan: try Meta.date(db, .lastFullScan), mapsBackoffUntil: try Meta.date(db, .mapsBackoffUntil),
            tables: tables, placeNameStatus: status, homeBases: homeBases, trips: trips, topPlaces: places)
    }
}
