import Foundation
import LZGeo
internal import GRDB

/// The structure pass (search spec §4), in the order each step's inputs need:
/// 1. **Home bases** (final runs): from located photos only, so nothing below changes them.
/// 2. **Zone borrowing** for the GPS-less assets within reach of the dirty days, adding the days it moves
///    assets into.
/// 3. **Days**: placement, moments, moment borrowing, labels and covers, day by day (``DayBuilder``).
/// 4. **Trips, cells and place counts** (final runs), over the whole library.
///
/// Work is split into small transactions, each with its dirty days, so a pause or a kill loses at most one and
/// readers see consistent days. A transaction that changes rows bumps the index version.
struct LiveStructurePass: StructurePass {
    /// Days per transaction.
    static let daysPerTransaction = 48

    func run(_ database: IndexDatabase, _ run: StructureRun) async throws -> Bool {
        let geo = run.geo
        var changed = false
        if run.final {
            changed = try await database.write { db in
                let changed = try HomeBaseFinder.update(db, geo: geo)
                if changed { try Meta.bumpVersion(db) }
                return changed
            }
            try await run.checkInterruption()
        }

        let after = run.daysAfter ?? .min
        let dirty = try await database.read { db in
            try Int32.fetchAll(db, sql: "SELECT day FROM dirty_day WHERE day > ? ORDER BY day DESC", arguments: [after])
        }
        if !dirty.isEmpty {
            var days = Set(dirty)
            for window in ZoneBorrowing.windows(for: dirty) {
                let result = try await database.write { db in
                    let result = try ZoneBorrowing.apply(db, window: window, deviceZone: run.deviceZone, geo: geo)
                    if result.changed > 0 { try Meta.bumpVersion(db) }
                    return result
                }
                // Days at or before a checkpoint's limit stay dirty for a later run.
                days.formUnion(result.moved.filter { $0 > after })
                changed = changed || result.changed > 0
                try await run.checkInterruption()
            }
            let context = try await database.read(DayContext.load)
            let ordered = days.sorted(by: >)
            for start in stride(from: 0, to: ordered.count, by: Self.daysPerTransaction) {
                let chunk = Array(ordered[start..<min(ordered.count, start + Self.daysPerTransaction)])
                let changes = try await database.write { db in
                    var builder = DayBuilder(db, geo: geo, context: context)
                    for day in chunk { try builder.rebuild(day: day) }
                    if builder.changes > 0 { try Meta.bumpVersion(db) }
                    return builder.changes
                }
                changed = changed || changes > 0
                try await run.checkInterruption()
            }
        }

        if run.final {
            let now = run.now
            changed = try await database.write { db in
                var changed = try TripBuilder.update(db)
                changed = try CellAggregator.update(db, geo: geo, now: now) > 0 || changed
                changed = try PlaceCounts.update(db) > 0 || changed
                if changed { try Meta.bumpVersion(db) }
                return changed
            } || changed
        }
        return changed
    }
}
