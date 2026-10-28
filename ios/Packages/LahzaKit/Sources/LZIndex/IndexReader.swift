import Foundation
import LZGeo
internal import GRDB

/// Read-only queries over the index. Each call is one database read, so it sees one consistent snapshot even
/// while a sync writes.
public struct IndexReader: Sendable {
    /// Which index session the reader belongs to (it changes when the index is purged or rebuilt).
    public let generation: Int
    let database: IndexDatabase

    init(database: IndexDatabase, generation: Int = 0) {
        self.database = database
        self.generation = generation
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
