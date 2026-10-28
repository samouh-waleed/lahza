import Foundation
import LZCore
import Synchronization
internal import GRDB

/// Where the index lives.
public enum IndexLocation: Sendable, Hashable {
    /// `Application Support/Index/` (the app).
    case applicationSupport
    /// `<url>/Index/` (tests, the seeded-library test).
    case directory(URL)
    /// In memory, gone when closed (tests, `-LZIndex memory`).
    case inMemory
}

public enum IndexError: Error, Sendable, Hashable {
    /// The database was closed (purge, Delete index); reads and writes fail from then on.
    case closed
}

/// The search index's one SQLite file, `Index/index.sqlite` (+ `-wal`, `-shm`): a derived, rebuildable cache
/// of the photo library, plus a few user tables.
///
/// Opening prepares the folder (data protection until first unlock, excluded from backups), then migrates,
/// or rebuilds when the file is damaged, comes from a newer build or from another rebuild epoch. A rebuild
/// keeps the user tables and empties the rest, so the next sync reads the library again. Every read and
/// write goes through a fence, so ``close()`` can wait for in-flight work before a purge removes the files.
/// GRDB types never leave the module.
public final class IndexDatabase: Sendable {
    public let location: IndexLocation
    let writer: any DatabaseWriter

    private struct Fence {
        var closed = false
        var inFlight = 0
    }

    private let fence = Mutex(Fence())
    private static let log = Log("index")
    static let fileName = "index.sqlite"
    /// Left next to the file when a job hits corruption; the next open rebuilds.
    static let rebuildMarker = "rebuild-needed"

    private init(location: IndexLocation, writer: any DatabaseWriter) {
        self.location = location
        self.writer = writer
    }

    // MARK: Opening

    /// Opens (creating, migrating or rebuilding as needed) the index at `location`.
    public static func open(_ location: IndexLocation) throws -> IndexDatabase {
        guard let folder = try folder(for: location) else {
            let queue = try DatabaseQueue(configuration: configuration())
            try IndexSchema.migrate(queue)
            return IndexDatabase(location: location, writer: queue)
        }
        try prepare(folder)
        let path = folder.appendingPathComponent(fileName).path
        let marker = folder.appendingPathComponent(rebuildMarker)
        var rebuildReason = FileManager.default.fileExists(atPath: marker.path) ? "damaged during a job" : nil
        if rebuildReason == nil {
            do {
                let pool = try DatabasePool(path: path, configuration: configuration())
                switch try pool.read(IndexSchema.state) {
                case .fresh, .current:
                    do {
                        try IndexSchema.migrate(pool)
                        return IndexDatabase(location: location, writer: pool)
                    } catch where !isTransient(error) {
                        rebuildReason = "migration failed (\(code(of: error)))"
                    }
                case .epochMismatch: rebuildReason = "rebuild epoch changed"
                case .superseded: rebuildReason = "written by a newer build"
                }
                try? pool.close()
            } catch where isDamaged(error) {
                rebuildReason = "damaged (\(code(of: error)))"
            }
        }
        return try rebuild(at: folder, location: location, reason: rebuildReason ?? "unknown")
    }

    /// Whether an index file exists at `location` (always false in memory).
    public static func exists(_ location: IndexLocation) -> Bool {
        guard let folder = try? folder(for: location) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path)
    }

    /// Removes the index folder (database, `-wal`, `-shm`). Unlinking open SQLite files is safe on Darwin, but
    /// call ``close()`` first so nothing writes into the unlinked file.
    public static func destroy(_ location: IndexLocation) throws {
        guard let folder = try folder(for: location), FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// The `Index/` folder, or nil in memory.
    static func folder(for location: IndexLocation) throws -> URL? {
        switch location {
        case .applicationSupport:
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return base.appendingPathComponent("Index", isDirectory: true)
        case .directory(let url):
            return url.appendingPathComponent("Index", isDirectory: true)
        case .inMemory:
            return nil
        }
    }

    /// Creates the folder with complete-until-first-unlock protection (new files, the WAL included, inherit it;
    /// never `.complete`, or WAL reads fail while locked) and excludes it from backups. Re-applied on every
    /// open, because restores can drop the flag.
    private static func prepare(_ folder: URL) throws {
        #if os(iOS)
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: protection)
        try FileManager.default.setAttributes(protection, ofItemAtPath: folder.path)
        #else
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = folder
        try url.setResourceValues(values)
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.label = "LZIndex"
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            // The data is rebuildable, so NORMAL durability is enough.
            try db.execute(sql: """
                PRAGMA synchronous = NORMAL;
                PRAGMA journal_size_limit = 16777216;
                PRAGMA temp_store = MEMORY;
                """)
        }
        return configuration
    }

    /// Exports the user tables it can still read, recreates the file and imports them again. The meta table
    /// starts empty, so the next sync is a full scan.
    private static func rebuild(at folder: URL, location: IndexLocation, reason: String) throws -> IndexDatabase {
        log.fault("Index rebuilt at open: \(reason)", privacy: .public)
        let path = folder.appendingPathComponent(fileName).path
        var kept = IndexSchema.UserRows()
        if let damaged = try? DatabaseQueue(path: path, configuration: configuration()) {
            kept = IndexSchema.UserRows.export(damaged)
            try? damaged.close()
        }
        for name in [fileName, fileName + "-wal", fileName + "-shm", rebuildMarker] {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let pool = try DatabasePool(path: path, configuration: configuration())
        try IndexSchema.migrate(pool)
        try kept.reimport(pool)
        log.notice("Index rebuild kept \(kept.rowCount) user rows", privacy: .public)
        return IndexDatabase(location: location, writer: pool)
    }

    // MARK: Errors

    /// SQLite says the file is not a database or is malformed.
    static func isDamaged(_ error: any Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        return error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    /// A condition that may pass (full disk, I/O, locked, no permission): never a reason to rebuild.
    static func isTransient(_ error: any Error) -> Bool {
        guard let error = error as? DatabaseError else { return error is CancellationError }
        let transient: [ResultCode] = [.SQLITE_FULL, .SQLITE_IOERR, .SQLITE_CANTOPEN, .SQLITE_BUSY, .SQLITE_LOCKED,
                                       .SQLITE_NOMEM, .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_AUTH, .SQLITE_INTERRUPT]
        return transient.contains(error.resultCode)
    }

    /// The SQLite result code, or the error's domain and code (never its message, which can quote SQL).
    static func code(of error: any Error) -> String {
        if let error = error as? DatabaseError { return "SQLite \(error.extendedResultCode.rawValue)" }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// Asks the next open to rebuild: a job hit corruption that the open-time checks may not see.
    func noteCorruption() {
        guard let folder = try? Self.folder(for: location) else { return }
        FileManager.default.createFile(atPath: folder.appendingPathComponent(Self.rebuildMarker).path, contents: nil)
    }

    /// A job found the file damaged: opening it again rebuilds it.
    public var needsRebuild: Bool {
        guard let folder = try? Self.folder(for: location) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.rebuildMarker).path)
    }

    // MARK: Access (fenced)

    /// One consistent snapshot read (WAL), even while a sync writes.
    func read<T: Sendable>(_ value: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try enter()
        defer { leave() }
        return try await writer.read(value)
    }

    /// One write transaction.
    func write<T: Sendable>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try enter()
        defer { leave() }
        return try await writer.write(updates)
    }

    /// Writes outside a transaction (checkpoints, `PRAGMA optimize`).
    func writeWithoutTransaction<T: Sendable>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try enter()
        defer { leave() }
        return try await writer.writeWithoutTransaction(updates)
    }

    private func enter() throws {
        try fence.withLock { fence in
            if fence.closed { throw IndexError.closed }
            fence.inFlight += 1
        }
    }

    private func leave() {
        fence.withLock { $0.inFlight -= 1 }
    }

    /// ``close()`` has been called.
    public var isClosed: Bool { fence.withLock { $0.closed } }

    // MARK: Maintenance

    /// The database file's size from SQLite's own counters (no file-attribute APIs).
    public func sizeBytes() async throws -> Int64 {
        try await read { db in
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return pages * size
        }
    }

    /// Truncates the WAL and refreshes the query planner's statistics: after a full scan, and on background.
    public func optimize(truncatingWAL: Bool = true) async throws {
        try await writeWithoutTransaction { db in
            if truncatingWAL { try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            try db.execute(sql: "PRAGMA optimize")
        }
    }

    /// Fences the database: new reads and writes throw ``IndexError/closed``; in-flight ones get up to 2 s to
    /// finish (polled every 50 ms); then the connections close.
    @concurrent public func close() async {
        let alreadyClosed = fence.withLock { fence in
            defer { fence.closed = true }
            return fence.closed
        }
        guard !alreadyClosed else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fence.withLock({ $0.inFlight }) > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? writer.close()
    }
}
