import Foundation
internal import GRDB

/// The `meta` table's keys: sync state, versions and timestamps (unix seconds).
enum MetaKey: String, CaseIterable {
    /// The change token the index is up to date with (absent until the first build finishes).
    case libraryToken
    /// The token taken at the start of a full scan; the catch-up delta starts from it.
    case pendingToken
    /// The mark-and-sweep generation of the latest full scan.
    case scanGen
    /// ``ScanPhase``.
    case scanPhase
    /// The oldest creation date read so far (rounded up to the second): the scan resumes at or before it.
    case scanFrontier
    case scanTotal, scanDone
    /// Why the current or latest full scan runs (``FullScanReason``).
    case scanReason
    /// `full` or `limited` when the latest full scan started.
    case accessScope
    case firstBuildDone
    case structureVersion, gazetteerVersion
    /// Bumped on every committed change readers should see.
    case indexVersion
    /// The device zone the GPS-less, unborrowed assets were derived with.
    case deviceTimeZone
    /// Located assets must be derived again (the gazetteer changed).
    case rederiveLocated
    /// Rows the library-wide structure steps read changed since they last ran: set in the transaction that
    /// changes them, cleared in the one that recomputes trips, cells and place counts.
    case structureDue
    case mapsBackoffUntil
    case lastSync, lastFullScan
    /// ``HomeOverride``: the person's home choice when it isn't a saved place (absent: estimate it). A user value:
    /// Rebuild keeps it and a rebuild at open carries it over (``IndexSchema/userMetaKeys``).
    case homeOverride
    /// The UUID the vector file (``VectorStore``) must carry to belong to these asset ids. Created when absent;
    /// Rebuild clears it and a rebuild at open starts without it, so vectors are never matched to reused ids.
    case vectorIdentity
    /// The Vision pass the index was set up with (``VisualPass/version``): present once the pass has started, which
    /// is when content search is on.
    case visualVersion
    /// A hash of the iPhone's Vision tag list: when an iOS update changes it, every photo is tagged again.
    case visualLabelsHash
}

/// ``MetaKey/homeOverride``'s values.
enum HomeOverride: String {
    /// No home: no home bases, so no trips, and "home" finds nothing.
    case none
}

/// Where a full scan is (``MetaKey/scanPhase``).
enum ScanPhase: String {
    case idle, dated, undated, catchup
}

/// Typed access to the `meta` table.
enum Meta {
    static func value(_ db: Database, _ key: MetaKey) throws -> DatabaseValue {
        try DatabaseValue.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key.rawValue]) ?? .null
    }

    static func int(_ db: Database, _ key: MetaKey) throws -> Int64? {
        Int64.fromDatabaseValue(try value(db, key))
    }

    static func string(_ db: Database, _ key: MetaKey) throws -> String? {
        String.fromDatabaseValue(try value(db, key))
    }

    static func data(_ db: Database, _ key: MetaKey) throws -> Data? {
        Data.fromDatabaseValue(try value(db, key))
    }

    static func date(_ db: Database, _ key: MetaKey) throws -> Date? {
        try int(db, key).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    static func phase(_ db: Database) throws -> ScanPhase {
        try string(db, .scanPhase).flatMap(ScanPhase.init(rawValue:)) ?? .idle
    }

    /// Stores `value`, or removes the key when it is nil.
    static func set(_ db: Database, _ key: MetaKey, _ value: (any DatabaseValueConvertible)?) throws {
        if let value {
            try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key.rawValue, value])
        } else {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key.rawValue])
        }
    }

    static func set(_ db: Database, _ key: MetaKey, date: Date?) throws {
        try set(db, key, date.map { Int64($0.timeIntervalSince1970.rounded(.down)) })
    }

    /// Records that the library-wide structure steps must run at the next final structure run.
    static func markStructureDue(_ db: Database) throws {
        try set(db, .structureDue, 1)
    }

    /// Adds one to ``MetaKey/indexVersion`` and returns the new value.
    @discardableResult
    static func bumpVersion(_ db: Database) throws -> Int64 {
        let version = (try int(db, .indexVersion) ?? 0) + 1
        try set(db, .indexVersion, version)
        return version
    }
}
