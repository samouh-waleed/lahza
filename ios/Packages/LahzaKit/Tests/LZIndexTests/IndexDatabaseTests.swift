import Foundation
import GRDB
import LZLibrary
import Testing
@testable import LZIndex

/// The index file: schema v1, the folder's flags, rebuilds at open (epoch, downgrade, corruption) that keep the
/// user tables, the Settings rebuild, the close fence and destroy.
@Suite struct IndexDatabaseTests {
    private func insertUserRows(_ database: IndexDatabase) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO saved_place (name, name_folded, lat, lon, radius_m, is_home, created_utc, updated_utc)
                VALUES ('My pitch', 'my pitch', 24.759, 46.644, 250, 0, 1, 2);
                INSERT INTO place_choice (phrase, place_key, radius_m, updated_utc) VALUES ('salam park', 'mk:salam', NULL, 3);
                INSERT INTO poi_cache (cell, fetched_at, status) VALUES ('th3xm4b', 4, 1);
                INSERT INTO map_search_cache (key, fetched_at, payload) VALUES ('sufra grill', 5, x'00');
                INSERT INTO meta (key, value) VALUES ('homeOverride', 'none');
                """)
        }
    }

    private func userRows(_ database: IndexDatabase) async throws -> (saved: [String], choices: [String]) {
        try await database.read { db in
            (try String.fetchAll(db, sql: "SELECT name FROM saved_place"), try String.fetchAll(db, sql: "SELECT place_key FROM place_choice"))
        }
    }

    /// Opens the file directly, outside IndexDatabase.
    private func raw(_ folder: URL, _ body: (Database) throws -> Void) throws {
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("Index/index.sqlite").path)
        try queue.writeWithoutTransaction(body)
        try queue.close()
    }

    // MARK: Schema

    @Test func schemaV1IsCreatedFromEmpty() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let (names, epoch, migrations) = try await database.read { db in
            (Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'trigger', 'index')")),
             try Int.fetchOne(db, sql: "PRAGMA user_version"), try IndexSchema.migrator.appliedMigrations(db))
        }
        for table in IndexSchema.tables + ["place_fts", "place_name_ai", "place_name_ad", "place_name_au", "asset_created", "cell_queue"] {
            #expect(names.contains(table), "missing \(table)")
        }
        #expect(epoch == IndexSchema.rebuildEpoch)
        #expect(migrations == ["v1", "v2-visual"])
        #expect(try await database.sizeBytes() > 0)
    }

    @Test func theFullTextIndexFollowsPlaceNames() async throws {
        let database = try IndexDatabase.open(.inMemory)
        func matches(_ query: String) async throws -> [Int64] {
            try await database.read { db in
                try Int64.fetchAll(db, sql: "SELECT rowid FROM place_fts WHERE place_fts MATCH ? ORDER BY bm25(place_fts), rowid", arguments: [query])
            }
        }
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO place (id, kind, key, name, source) VALUES (1, 5, 'mk:nakheel', 'Al-Nakheel Park', 2), (2, 3, 'gn:2657896', 'Zürich', 1);
                INSERT INTO place_name (id, place_id, name) VALUES (10, 1, 'al nakheel park'), (11, 1, 'nakheel park'), (12, 2, 'zürich');
                """)
        }
        #expect(try await matches("nakheel") == [11, 10])
        #expect(try await matches("nakh*") == [11, 10], "prefix search")
        #expect(try await matches("zurich") == [12], "diacritics are folded")

        try await database.write { db in try db.execute(sql: "UPDATE place_name SET name = 'zuerich' WHERE id = 12") }
        #expect(try await matches("zurich").isEmpty)
        #expect(try await matches("zuerich") == [12])

        try await database.write { db in try db.execute(sql: "DELETE FROM place WHERE id = 1") }
        #expect(try await Fixture.count(database, "place_name") == 1, "names cascade with their place")
        #expect(try await matches("nakheel").isEmpty, "and leave the full-text index")
    }

    // MARK: Files

    @Test func openingPreparesTheFolderAndKeepsTheData() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let location = IndexLocation.directory(url)
            #expect(!IndexDatabase.exists(location))
            let database = try IndexDatabase.open(location)
            try await insertUserRows(database)
            let folder = url.appendingPathComponent("Index")
            #expect(IndexDatabase.exists(location))
            #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            #expect(try await database.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") } == "wal")
            #expect(try await database.read { db in try Int.fetchOne(db, sql: "PRAGMA synchronous") } == 1, "NORMAL")
            await database.close()

            let reopened = try IndexDatabase.open(location)
            #expect(try await userRows(reopened).saved == ["My pitch"])
            #expect(try await Fixture.count(reopened, "poi_cache") == 1)
            await reopened.close()
        }
    }

    @Test func aDifferentRebuildEpochRebuildsAndKeepsTheUserTables() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            try await insertUserRows(database)
            await Fixture.sync(Fixture.indexer(database, FakeLibraryReader(.explicit(Fixture.library(5)))))
            #expect(try await Fixture.count(database, "asset") == 5)
            await database.close()
            try raw(url) { db in try db.execute(sql: "PRAGMA user_version = 999") }

            let rebuilt = try IndexDatabase.open(.directory(url))
            #expect(try await userRows(rebuilt).saved == ["My pitch"])
            #expect(try await userRows(rebuilt).choices == ["mk:salam"])
            #expect(try await rebuilt.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'homeOverride'") } == "none",
                    "the home choice is kept too")
            #expect(try await rebuilt.read { db in try String.fetchAll(db, sql: "SELECT n.name FROM place_name n JOIN place p ON p.id = n.place_id WHERE p.key = 'saved:1' ORDER BY n.name") }
                    == ["my pitch", "pitch"], "saved places are mirrored into the place index again")
            #expect(try await Fixture.count(rebuilt, "asset") == 0)
            #expect(try await Fixture.count(rebuilt, "poi_cache") == 0, "only the user tables survive")
            #expect(try await Fixture.meta(rebuilt).phase == .idle)
            #expect(try await Fixture.meta(rebuilt).libraryToken == nil, "so the next sync is a full scan")
            #expect(try await rebuilt.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") } == IndexSchema.rebuildEpoch)
            await rebuilt.close()
        }
    }

    @Test func aFileFromANewerBuildRebuildsAndKeepsTheUserTables() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            try await insertUserRows(database)
            await database.close()
            try raw(url) { db in try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v9-future')") }

            let rebuilt = try IndexDatabase.open(.directory(url))
            #expect(try await userRows(rebuilt).saved == ["My pitch"])
            #expect(try await rebuilt.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") } == ["v1", "v2-visual"])
            await rebuilt.close()
        }
    }

    @Test func aDamagedFileRebuildsAndKeepsWhatItCanRead() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            try await insertUserRows(database)
            await database.close()
            // Overwrite the migrations table's page: reading it at open fails with SQLITE_CORRUPT.
            var page = 0, pageSize = 0
            try raw(url) { db in
                page = try Int.fetchOne(db, sql: "SELECT rootpage FROM sqlite_master WHERE name = 'grdb_migrations'") ?? 0
                pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            }
            #expect(page > 1)
            let file = try FileHandle(forWritingTo: url.appendingPathComponent("Index/index.sqlite"))
            try file.seek(toOffset: UInt64((page - 1) * pageSize))
            try file.write(contentsOf: Data(repeating: 0xA5, count: pageSize))
            try file.close()

            let rebuilt = try IndexDatabase.open(.directory(url))
            #expect(try await userRows(rebuilt).saved == ["My pitch"])
            #expect(try await userRows(rebuilt).choices == ["mk:salam"])
            await rebuilt.close()
        }
    }

    @Test func aFileThatIsNotADatabaseRebuildsEmpty() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let folder = url.appendingPathComponent("Index")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((0..<8_192).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: folder.appendingPathComponent("index.sqlite"))

            let rebuilt = try IndexDatabase.open(.directory(url))
            #expect(try await Fixture.count(rebuilt, "saved_place") == 0)
            await Fixture.sync(Fixture.indexer(rebuilt, FakeLibraryReader(.explicit(Fixture.library(3)))))
            #expect(try await Fixture.count(rebuilt, "asset") == 3)
            await rebuilt.close()
        }
    }

    @Test func corruptionNotedDuringAJobRebuildsAtTheNextOpen() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let database = try IndexDatabase.open(.directory(url))
            try await insertUserRows(database)
            await Fixture.sync(Fixture.indexer(database, FakeLibraryReader(.explicit(Fixture.library(4)))))
            database.noteCorruption()
            await database.close()

            let rebuilt = try IndexDatabase.open(.directory(url))
            #expect(try await Fixture.count(rebuilt, "asset") == 0)
            #expect(try await userRows(rebuilt).saved == ["My pitch"])
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("Index/\(IndexDatabase.rebuildMarker)").path))
            await rebuilt.close()
        }
    }

    // MARK: Rebuild, close, destroy

    @Test func rebuildEmptiesTheDerivedTablesAndKeepsUserTablesAndCaches() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let reader = FakeLibraryReader(.explicit(Fixture.library(12)))
        let indexer = Fixture.indexer(database, reader)
        await Fixture.sync(indexer)
        try await insertUserRows(database)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO place (id, kind, key, name, source) VALUES (1, 3, 'gn:108410', 'Riyadh', 1), (2, 6, 'saved:1', 'My pitch', 3),
                  (3, 8, 'mk:sufra', 'Sufra Grill', 2);
                INSERT INTO place_name (place_id, name) VALUES (1, 'riyadh'), (2, 'my pitch'), (3, 'sufra grill');
                INSERT INTO moment (day, start_utc, end_utc, start_wall, end_wall, first_asset, item_count, photo_count, video_count,
                  located_count, borrowed_count) VALUES (1, 1, 2, 1, 2, 1, 1, 1, 0, 0, 0);
                INSERT INTO trip (start_day, end_day, label, abroad, moment_count, item_count, video_count, max_km) VALUES (1, 3, 'Greece', 1, 1, 1, 0, 900);
                INSERT INTO home_base (year, lat, lon, tile, nights, source) VALUES (2025, 24.748, 46.633, 'th3xm4', 12, 0);
                INSERT INTO cell (cell, lat, lon, photo_count, day_count) VALUES ('th3xm4b', 24.759, 46.644, 3, 1);
                """)
        }
        reader.delete(["a00000"])
        await Fixture.sync(indexer, .rebuild)

        #expect(await indexer.stats.fullScans == [.firstRun: 1, .rebuild: 1])
        #expect(try await Fixture.count(database, "asset") == 11)
        for table in ["moment", "trip", "home_base", "cell"] { #expect(try await Fixture.count(database, table) == 0, "\(table)") }
        #expect(try await database.read { db in try String.fetchAll(db, sql: "SELECT key FROM place ORDER BY id") } == ["saved:1", "mk:sufra"])
        #expect(try await database.read { db in try String.fetchAll(db, sql: "SELECT name FROM place_name ORDER BY name") } == ["my pitch", "sufra grill"])
        #expect(try await userRows(database).saved == ["My pitch"])
        #expect(try await Fixture.count(database, "poi_cache") == 1)
        #expect(try await Fixture.count(database, "map_search_cache") == 1)
        #expect(try await Fixture.meta(database).firstBuildDone)
    }

    @Test func closingFencesReadsAndWaitsForThoseInFlight() async throws {
        let database = try IndexDatabase.open(.inMemory)
        let slow = Task {
            try await database.read { db -> Int in
                Thread.sleep(forTimeInterval: 0.2)
                return try Int.fetchOne(db, sql: "SELECT 1") ?? 0
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        await database.close()
        #expect(try await slow.value == 1, "the in-flight read finished before the connection closed")
        #expect(database.isClosed)
        await #expect(throws: IndexError.closed) { try await database.sizeBytes() }
        await #expect(throws: IndexError.closed) { try await IndexReader(database: database).summary() }
        await #expect(throws: IndexError.closed) { try await database.write { db in try db.execute(sql: "DELETE FROM meta") } }
    }

    @Test func destroyRemovesTheIndexFolder() async throws {
        try await Fixture.withTemporaryDirectory { url in
            let location = IndexLocation.directory(url)
            let database = try IndexDatabase.open(location)
            await Fixture.sync(Fixture.indexer(database, FakeLibraryReader(.explicit(Fixture.library(3)))))
            await database.close()
            try IndexDatabase.destroy(location)
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("Index").path))
            #expect(!IndexDatabase.exists(location))
            try IndexDatabase.destroy(location) // nothing left: no error
        }
    }
}
