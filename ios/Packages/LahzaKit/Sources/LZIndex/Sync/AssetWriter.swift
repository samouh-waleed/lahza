import Foundation
import LZGeo
import LZLibrary
internal import GRDB

/// Rows written by one or more batches (logs, the inspector and the tests' write counting).
struct WriteCounts: Sendable, Hashable {
    var inserted = 0
    /// Rows whose facts changed and were rewritten.
    var updated = 0
    /// Rows re-read with the same fingerprint: at most their scan generation is touched.
    var unchanged = 0
    var deleted = 0

    var changed: Int { inserted + updated + deleted }

    static func += (lhs: inout WriteCounts, rhs: WriteCounts) {
        lhs.inserted += rhs.inserted
        lhs.updated += rhs.updated
        lhs.unchanged += rhs.unchanged
        lhs.deleted += rhs.deleted
    }
}

/// Upserts and deletes `asset` rows inside one write transaction, and records which moment days they touch in
/// `dirty_day` (old and new day on every change), so the structure pass knows what to recompute.
struct AssetWriter {
    let db: Database
    var derivation: AssetDerivation
    private(set) var counts = WriteCounts()
    /// Upserted records whose row this scan generation had already stamped (a resumed scan re-reads its frontier).
    private(set) var repeated = 0
    private var dirtyDays = Set<Int32>()

    init(_ db: Database, geo: GeoCache, deviceZone: String) throws {
        self.db = db
        derivation = try AssetDerivation(db, geo: geo, deviceZone: deviceZone)
    }

    private struct Existing {
        var id: Int64
        var fingerprint: Int64
        var generation: Int64
        var day: Int32?
    }

    private static let columns = """
        kind, subtypes, flags, created_utc, added_utc, modified_utc, adjusted_utc, lat, lon, h_acc, duration, width, height,
        source, meta_fp, scan_gen, tz, tz_src, wall_s, day, cell, place_src, eff_lat, eff_lon,
        city_place, metro_place, locality_place, region_place, country_place
        """
    private static let columnNames = columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static let insertSQL = "INSERT INTO asset (local_id, \(columns)) VALUES (?, \(columnNames.map { _ in "?" }.joined(separator: ", ")))"
    private static let updateSQL = "UPDATE asset SET \(columnNames.map { "\($0) = ?" }.joined(separator: ", ")) WHERE id = ?"

    /// Inserts new assets, rewrites changed ones and only stamps `generation` on unchanged ones.
    mutating func upsert(_ records: [AssetRecord], generation: Int64) throws {
        guard !records.isEmpty else { return }
        let existing = try existingRows(records.map(\.localID))
        for record in records {
            if let old = existing[record.localID] {
                if old.generation == generation { repeated += 1 }
                if old.fingerprint == record.fingerprint {
                    counts.unchanged += 1
                    if old.generation != generation {
                        try db.cachedStatement(sql: "UPDATE asset SET scan_gen = ? WHERE id = ?").execute(arguments: [generation, old.id])
                    }
                    continue
                }
                let derived = try derivation.derive(record, db)
                var arguments = Self.values(record, derived, generation: generation)
                arguments.append(old.id)
                try db.cachedStatement(sql: Self.updateSQL).execute(arguments: StatementArguments(arguments))
                counts.updated += 1
                markDirty(old.day)
                markDirty(derived.day)
            } else {
                let derived = try derivation.derive(record, db)
                var arguments: [(any DatabaseValueConvertible)?] = [record.localID]
                arguments += Self.values(record, derived, generation: generation)
                try db.cachedStatement(sql: Self.insertSQL).execute(arguments: StatementArguments(arguments))
                counts.inserted += 1
                markDirty(derived.day)
            }
        }
    }

    /// Derives an existing asset's zone, wall time, day and cell again (a new device zone or gazetteer), leaving
    /// its facts and borrowed position alone. A changed value marks its day dirty (both days when it moves), since
    /// its moment's times, zone and places come from it.
    mutating func rederive(_ old: Rederivable) throws {
        let derived = try derivation.derive(created: old.created, coordinate: old.coordinate, db)
        guard derived.zone != old.zone || derived.zoneSource.rawValue != old.zoneSource || derived.wallSeconds != old.wall
            || derived.day != old.day || derived.cell != old.cell else { return }
        try db.cachedStatement(sql: "UPDATE asset SET tz = ?, tz_src = ?, wall_s = ?, day = ?, cell = ? WHERE id = ?")
            .execute(arguments: [derived.zone, derived.zoneSource.rawValue, derived.wallSeconds, derived.day, derived.cell, old.id])
        markDirty(old.day)
        markDirty(derived.day)
    }

    /// An asset's derived columns, as ``rederive(_:)`` reads them.
    struct Rederivable {
        static let columns = "id, created_utc, lat, lon, tz, tz_src, wall_s, day, cell"

        var id: Int64
        var created: Int64?
        var coordinate: Coordinate?
        var zone: Int64?
        var zoneSource: Int
        var wall: Int64?
        var day: Int32?
        var cell: String?

        init(_ row: Row) {
            id = row["id"]
            created = row["created_utc"]
            coordinate = (row["lat"] as Double?).flatMap { lat in (row["lon"] as Double?).map { Coordinate(latitude: lat, longitude: $0) } }
            zone = row["tz"]
            zoneSource = row["tz_src"]
            wall = row["wall_s"]
            day = row["day"]
            cell = row["cell"]
        }
    }

    /// Deletes these assets (gone, hidden, no longer shared) when indexed.
    mutating func delete(localIDs: [String]) throws {
        for chunk in Self.chunks(localIDs) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let arguments = StatementArguments(chunk)
            for day in try Int32.fetchAll(db, sql: "SELECT DISTINCT day FROM asset WHERE day IS NOT NULL AND local_id IN (\(marks))", arguments: arguments) {
                markDirty(day)
            }
            try db.execute(sql: "DELETE FROM asset WHERE local_id IN (\(marks))", arguments: arguments)
            counts.deleted += db.changesCount
        }
    }

    /// The sweep of a full scan: deletes every asset the scan of `generation` didn't see.
    mutating func sweep(olderThan generation: Int64) throws {
        for day in try Int32.fetchAll(db, sql: "SELECT DISTINCT day FROM asset WHERE day IS NOT NULL AND scan_gen < ?", arguments: [generation]) {
            markDirty(day)
        }
        try db.execute(sql: "DELETE FROM asset WHERE scan_gen < ?", arguments: [generation])
        counts.deleted += db.changesCount
    }

    /// Writes the touched days to `dirty_day`, and marks the library-wide structure steps due when a row changed
    /// (an undated asset touches no day). Call once, before the transaction commits.
    mutating func finish() throws {
        if counts.changed > 0 || !dirtyDays.isEmpty { try Meta.markStructureDue(db) }
        let statement = try db.cachedStatement(sql: "INSERT OR IGNORE INTO dirty_day (day) VALUES (?)")
        for day in dirtyDays { try statement.execute(arguments: [day]) }
        dirtyDays.removeAll()
    }

    mutating func markDirty(_ day: Int32?) {
        if let day { dirtyDays.insert(day) }
    }

    private func existingRows(_ localIDs: [String]) throws -> [String: Existing] {
        var rows: [String: Existing] = [:]
        rows.reserveCapacity(localIDs.count)
        for chunk in Self.chunks(localIDs) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let cursor = try Row.fetchCursor(db, sql: "SELECT id, local_id, meta_fp, scan_gen, day FROM asset WHERE local_id IN (\(marks))",
                                             arguments: StatementArguments(chunk))
            while let row = try cursor.next() {
                rows[row["local_id"]] = Existing(id: row["id"], fingerprint: row["meta_fp"], generation: row["scan_gen"], day: row["day"])
            }
        }
        return rows
    }

    /// SQLite's variable limit is far above this; 900 keeps statements small.
    private static func chunks(_ ids: [String]) -> [ArraySlice<String>] {
        stride(from: 0, to: ids.count, by: 900).map { ids[$0..<min(ids.count, $0 + 900)] }
    }

    /// Column values in ``columns`` order.
    private static func values(_ record: AssetRecord, _ derived: DerivedColumns, generation: Int64) -> [(any DatabaseValueConvertible)?] {
        [record.kind, record.subtypes, record.flags.rawValue, record.created, record.added, record.modified, record.adjusted,
         record.latitude, record.longitude, record.accuracy, record.duration, record.width, record.height,
         record.source, record.fingerprint, generation, derived.zone, derived.zoneSource.rawValue, derived.wallSeconds, derived.day,
         derived.cell, derived.placeSource.rawValue, derived.effectiveLatitude, derived.effectiveLongitude,
         nil as Int64?, nil as Int64?, nil as Int64?, nil as Int64?, nil as Int64?]
    }
}
