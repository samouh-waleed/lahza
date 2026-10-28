import Foundation
import LZIndex
import SQLite3
import Testing

/// The search index on the iOS runtime: its folder keeps data protection until first unlock and stays out of
/// backups, and the system SQLite runs the schema's FTS5 place search.
@Suite struct IndexStorageTests {
    private func withIndex<T>(_ body: (URL) async throws -> T) async throws -> T {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let database = try IndexDatabase.open(.directory(base))
        await database.close()
        return try await body(base.appendingPathComponent("Index", isDirectory: true))
    }

    @Test func theIndexFolderIsProtectedUntilFirstUnlockAndNotBackedUp() async throws {
        try await withIndex { folder in
            let protection = try FileManager.default.attributesOfItem(atPath: folder.path)[.protectionKey] as? FileProtectionType
            #if targetEnvironment(simulator)
            // The Simulator has no data protection: it accepts the class and reports none back.
            #expect(protection == nil || protection == .completeUntilFirstUserAuthentication)
            #else
            #expect(protection == .completeUntilFirstUserAuthentication)
            #endif
            #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
    }

    @Test func placeNamesAreFoundWithFullTextSearch() async throws {
        try await withIndex { folder in
            var db: OpaquePointer?
            #expect(sqlite3_open(folder.appendingPathComponent("index.sqlite").path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            let insert = """
                INSERT INTO place (id, kind, key, name, source) VALUES (1, 5, 'mk:nakheel', 'Al-Nakheel Park', 2);
                INSERT INTO place_name (id, place_id, name) VALUES (10, 1, 'al nakheel park'), (11, 1, 'nakheel park');
                """
            #expect(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK)
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "SELECT rowid FROM place_fts WHERE place_fts MATCH 'nakh*' ORDER BY rowid", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            var rows: [Int64] = []
            while sqlite3_step(statement) == SQLITE_ROW { rows.append(sqlite3_column_int64(statement, 0)) }
            #expect(rows == [10, 11])
        }
    }
}
