import Foundation

/// P0b, the structure pass over `dirty_day`: zone borrowing, moments, home bases, trips, cells and place counts
/// (search spec §4). ``LibraryIndexer`` runs it as part of its jobs, so it is the only writer of those tables:
///
/// - at every progressive checkpoint of a full scan, over the dirty days later than `day`: those days are
///   complete, because the scan reads newest first;
/// - at the end of every job (sync, rebuild, restructure), over every dirty day, with `final` set so it also
///   recomputes what spans the library (home bases, trips, place counts).
///
/// It removes the days it has processed from `dirty_day`, and puts back days its zone borrowing moved assets
/// into. It returns whether readers would see a change (the indexer then bumps the index version).
protocol StructurePass: Sendable {
    func run(_ database: IndexDatabase, daysAfter day: Int32?, final: Bool) async throws -> Bool
}

/// Until the structure pass lands, dirty days wait in `dirty_day`, so the first real pass sees every day.
struct DeferredStructurePass: StructurePass {
    func run(_ database: IndexDatabase, daysAfter day: Int32?, final: Bool) async throws -> Bool { false }
}
