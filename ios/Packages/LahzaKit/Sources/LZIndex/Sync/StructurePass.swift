import Foundation

/// P0b, the structure pass over `dirty_day`: zone borrowing, placement, moments, home bases, trips, cells and
/// place counts (search spec §4). ``LibraryIndexer`` runs it as part of its jobs, so it is the only writer of
/// those tables:
///
/// - at every progressive checkpoint of a full scan, over the dirty days later than ``StructureRun/daysAfter``:
///   those days are complete, because the scan reads newest first;
/// - at the end of every job (sync, rebuild, restructure), over every dirty day, with ``StructureRun/final``
///   set so it also recomputes what spans the library (home bases, trips, cells, place counts) when anything
///   those read changed since they last ran.
///
/// It removes each day from `dirty_day` in the transaction that processes it, and adds the days its zone
/// borrowing moves assets into. It returns whether readers would see a change.
protocol StructurePass: Sendable {
    func run(_ database: IndexDatabase, _ run: StructureRun) async throws -> Bool
}

/// One structure run's inputs.
struct StructureRun: Sendable {
    /// Only dirty days after this one (a progressive checkpoint); nil for every dirty day.
    var daysAfter: Int32?
    /// The end of a job: home bases, trips, cells and place counts too.
    var final: Bool
    /// The device zone GPS-less assets fall back to.
    var deviceZone: String
    var now: Date
    var geo: GeoCache
    /// Throws to stop between transactions (a pause or a cancel).
    var checkInterruption: @Sendable () async throws -> Void
}

/// A pass that leaves dirty days waiting in `dirty_day` (tests of the sync alone).
struct DeferredStructurePass: StructurePass {
    func run(_ database: IndexDatabase, _ run: StructureRun) async throws -> Bool { false }
}
