import Foundation
import LZGeo
internal import GRDB

/// Zone borrowing (search spec §4.1). PhotoKit has no capture zone, so a dated asset without GPS takes, in order:
/// 1. the zone of the located asset nearest in time within ±12 h (a tie goes to the earlier one): `tz_src` 1;
/// 2. the home base's zone for its local year: `tz_src` 2;
/// 3. the device zone: `tz_src` 3.
///
/// The zone sets its wall time and moment day, so borrowing can move an asset to another day; both days are then
/// marked dirty. A GPS-less asset's zone depends only on located assets within 12 h, so after a change on some
/// days only the GPS-less assets within reach of those days' UTC span need borrowing again.
enum ZoneBorrowing {
    static let reach: Int64 = 12 * 3_600
    /// Windows are cut into pieces of at most this span, one transaction each.
    static let pieceSpan: Int64 = 30 * 86_400

    /// The UTC seconds a moment day can hold in any zone: 04:00 to 04:00 local, at UTC−12 to UTC+14.
    static func utcSpan(of day: Int32) -> ClosedRange<Int64> {
        let start = Int64(day) * 86_400 + LocalTime.dayBreak
        return (start - 14 * 3_600)...(start + 86_400 + 12 * 3_600)
    }

    /// The UTC windows holding every GPS-less asset whose borrowing a change on `days` can affect: each day's
    /// span widened by the reach, merged and cut into pieces.
    static func windows(for days: some Sequence<Int32>) -> [ClosedRange<Int64>] {
        let spans = days.map { day -> ClosedRange<Int64> in
            let span = utcSpan(of: day)
            return (span.lowerBound - reach)...(span.upperBound + reach)
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int64>] = []
        for span in spans {
            if let last = merged.last, span.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged.flatMap { window -> [ClosedRange<Int64>] in
            stride(from: window.lowerBound, through: window.upperBound, by: Int(pieceSpan)).map { start in
                start...min(window.upperBound, start + pieceSpan - 1)
            }
        }
    }

    /// Borrows zones for the GPS-less dated assets created in `window`, writing only those that change. Returns
    /// the days assets moved out of or into (already in `dirty_day`) and how many rows changed.
    static func apply(_ db: Database, window: ClosedRange<Int64>, deviceZone: String, geo: GeoCache) throws -> (moved: Set<Int32>, changed: Int) {
        let unlocated = try Row.fetchAll(db, sql: """
            SELECT id, created_utc, tz, tz_src, wall_s, day FROM asset
            WHERE lat IS NULL AND created_utc BETWEEN ? AND ? ORDER BY created_utc, id
            """, arguments: [window.lowerBound, window.upperBound])
        guard !unlocated.isEmpty else { return ([], 0) }
        let located = try Row.fetchAll(db, sql: """
            SELECT created_utc, tz FROM asset WHERE lat IS NOT NULL AND tz IS NOT NULL AND created_utc BETWEEN ? AND ? ORDER BY created_utc, id
            """, arguments: [window.lowerBound - reach, window.upperBound + reach]).map { (utc: $0["created_utc"] as Int64, zone: $0["tz"] as Int64) }
        var zones = ZoneTable(try Row.fetchAll(db, sql: "SELECT id, name FROM zone"))
        var homes: [Int: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT year, tz FROM home_base WHERE tz IS NOT NULL") { homes[row["year"]] = row["tz"] }
        let device = try zones.id(deviceZone, db)

        var moved = Set<Int32>()
        var changed = 0
        var next = 0
        let update = try db.cachedStatement(sql: "UPDATE asset SET tz = ?, tz_src = ?, wall_s = ?, day = ? WHERE id = ?")
        for row in unlocated {
            let utc: Int64 = row["created_utc"]
            while next < located.count, located[next].utc < utc { next += 1 }
            // The nearest located asset within reach; the earlier one on a tie.
            var best: (gap: Int64, zone: Int64)?
            if next > 0, utc - located[next - 1].utc <= reach { best = (utc - located[next - 1].utc, located[next - 1].zone) }
            if next < located.count, located[next].utc - utc <= reach, located[next].utc - utc < (best?.gap ?? .max) {
                best = (located[next].utc - utc, located[next].zone)
            }
            let oldDay: Int32? = row["day"]
            let zone: Int64
            let source: ZoneSource
            if let best {
                zone = best.zone
                source = .borrowed
            } else if let home = homes[(oldDay ?? LocalTime.momentDay(wallSeconds: utc)).civilYear] {
                zone = home
                source = .home
            } else {
                zone = device
                source = .device
            }
            let wall = LocalTime.wallSeconds(Date(timeIntervalSince1970: TimeInterval(utc)), in: geo.timeZone(zones.name(zone) ?? deviceZone))
            let day = LocalTime.momentDay(wallSeconds: wall)
            guard zone != row["tz"] || source.rawValue != row["tz_src"] || wall != row["wall_s"] || day != oldDay else { continue }
            try update.execute(arguments: [zone, source.rawValue, wall, day, row["id"]])
            changed += 1
            if day != oldDay {
                if let oldDay { moved.insert(oldDay) }
                moved.insert(day)
            }
        }
        let dirty = try db.cachedStatement(sql: "INSERT OR IGNORE INTO dirty_day (day) VALUES (?)")
        for day in moved { try dirty.execute(arguments: [day]) }
        return (moved, changed)
    }
}

/// The `zone` table both ways, inserting names on first use.
struct ZoneTable {
    private var ids: [String: Int64] = [:]
    private var names: [Int64: String] = [:]

    init(_ rows: [Row]) {
        for row in rows {
            ids[row["name"]] = row["id"]
            names[row["id"]] = row["name"]
        }
    }

    func name(_ id: Int64) -> String? { names[id] }

    mutating func id(_ name: String, _ db: Database) throws -> Int64 {
        if let id = ids[name] { return id }
        try db.execute(sql: "INSERT OR IGNORE INTO zone (name) VALUES (?)", arguments: [name])
        let id = try Int64.fetchOne(db, sql: "SELECT id FROM zone WHERE name = ?", arguments: [name]) ?? db.lastInsertedRowID
        ids[name] = id
        names[id] = name
        return id
    }
}

extension Int32 {
    /// The civil year of this moment day.
    var civilYear: Int { LocalTime.civil(day: self).year }
}
