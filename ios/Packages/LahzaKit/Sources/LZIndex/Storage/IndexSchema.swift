import Foundation
internal import GRDB

/// The index's SQLite schema: append-only named migrations in raw SQL, the rebuild epoch and the user
/// tables that survive a rebuild.
///
/// Shipped migrations are never edited. A destructive change bumps ``rebuildEpoch`` instead: at open a
/// mismatch exports the user tables, recreates the file and imports them again (see ``IndexDatabase``).
enum IndexSchema {
    /// Stored in `PRAGMA user_version`. Bump it for a change no migration can express; the index is
    /// then rebuilt from the library at the next open, keeping the user tables.
    static let rebuildEpoch = 1

    /// The structure rules' version (P0b). Bump it when moments, trips, home bases or labels are
    /// computed differently: every day is restructured at the next job, without a library rescan.
    static let structureVersion = 1

    /// User tables: they survive a rebuild and are erased by purge and Delete index.
    static let userTables = ["saved_place", "place_choice"]

    /// User values kept in `meta`: like the user tables, they survive a rebuild.
    static let userMetaKeys: [MetaKey] = [.homeOverride]

    /// Every table, in schema order (the inspector's row counts).
    static let tables = [
        "meta", "zone", "asset", "moment", "trip", "home_base", "place", "place_name", "cell", "dirty_day",
        "poi_cache", "map_search_cache", "saved_place", "place_choice", "visual_label", "asset_label", "asset_visual",
    ]

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // A migration edited during development erases the database (user tables included).
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        migrator.registerMigration("v1") { db in try db.execute(sql: v1) }
        migrator.registerMigration("v2-visual") { db in try db.execute(sql: v2Visual) }
        return migrator
    }

    /// Schema v1 (search v0). Columns are documented in plan-docs' search spec §2.2; derived columns are
    /// filled by the indexer's derivation and structure passes.
    static let v1 = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB);

        CREATE TABLE zone (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);

        CREATE TABLE asset (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          local_id      TEXT NOT NULL UNIQUE,
          kind          INTEGER NOT NULL,
          subtypes      INTEGER NOT NULL DEFAULT 0,
          flags         INTEGER NOT NULL DEFAULT 0,
          created_utc   INTEGER, added_utc INTEGER, modified_utc INTEGER, adjusted_utc INTEGER,
          lat REAL, lon REAL, h_acc REAL,
          duration      REAL NOT NULL DEFAULT 0,
          width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0,
          source        INTEGER NOT NULL DEFAULT 0,
          meta_fp       INTEGER NOT NULL,
          scan_gen      INTEGER NOT NULL,
          tz            INTEGER REFERENCES zone(id),
          tz_src        INTEGER NOT NULL DEFAULT 3,
          wall_s        INTEGER,
          day           INTEGER,
          cell          TEXT,
          place_src     INTEGER NOT NULL DEFAULT 0,
          eff_lat REAL, eff_lon REAL,
          city_place INTEGER, metro_place INTEGER, locality_place INTEGER, region_place INTEGER, country_place INTEGER,
          moment_id     INTEGER, trip_id INTEGER
        );
        CREATE INDEX asset_created ON asset(created_utc DESC);
        CREATE INDEX asset_day     ON asset(day);
        CREATE INDEX asset_moment  ON asset(moment_id);
        CREATE INDEX asset_cell    ON asset(cell) WHERE cell IS NOT NULL;

        CREATE TABLE moment (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          day INTEGER NOT NULL, start_utc INTEGER NOT NULL, end_utc INTEGER NOT NULL,
          start_wall INTEGER NOT NULL, end_wall INTEGER NOT NULL, tz INTEGER,
          first_asset INTEGER NOT NULL, item_count INTEGER NOT NULL, photo_count INTEGER NOT NULL, video_count INTEGER NOT NULL,
          located_count INTEGER NOT NULL, borrowed_count INTEGER NOT NULL,
          lat REAL, lon REAL, spread_m REAL, cell TEXT,
          label_place INTEGER, city_place INTEGER, country_place INTEGER,
          trip_id INTEGER, cover_asset INTEGER,
          UNIQUE(day, start_utc)
        );
        CREATE INDEX moment_day ON moment(day DESC, start_utc DESC);

        CREATE TABLE trip (
          id INTEGER PRIMARY KEY AUTOINCREMENT, start_day INTEGER NOT NULL UNIQUE, end_day INTEGER NOT NULL,
          label TEXT NOT NULL, label_place INTEGER, country_place INTEGER, abroad INTEGER NOT NULL,
          moment_count INTEGER NOT NULL, item_count INTEGER NOT NULL, video_count INTEGER NOT NULL,
          max_km REAL NOT NULL, cover_asset INTEGER
        );

        CREATE TABLE home_base (
          year INTEGER PRIMARY KEY, lat REAL NOT NULL, lon REAL NOT NULL, tile TEXT NOT NULL,
          tz INTEGER, country_code TEXT, nights INTEGER NOT NULL, source INTEGER NOT NULL
        );

        CREATE TABLE place (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          kind INTEGER NOT NULL,
          key  TEXT NOT NULL UNIQUE,
          name TEXT NOT NULL, category TEXT,
          lat REAL, lon REAL, radius_m REAL,
          country_code TEXT, photo_count INTEGER NOT NULL DEFAULT 0, last_utc INTEGER,
          source INTEGER NOT NULL
        );
        CREATE TABLE place_name (
          id INTEGER PRIMARY KEY, place_id INTEGER NOT NULL REFERENCES place(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          UNIQUE(place_id, name)
        );
        CREATE VIRTUAL TABLE place_fts USING fts5(name, content='place_name', content_rowid='id',
          tokenize='unicode61 remove_diacritics 2', prefix='2 3');
        CREATE TRIGGER place_name_ai AFTER INSERT ON place_name BEGIN
          INSERT INTO place_fts(rowid, name) VALUES (new.id, new.name);
        END;
        CREATE TRIGGER place_name_ad AFTER DELETE ON place_name BEGIN
          INSERT INTO place_fts(place_fts, rowid, name) VALUES ('delete', old.id, old.name);
        END;
        CREATE TRIGGER place_name_au AFTER UPDATE ON place_name BEGIN
          INSERT INTO place_fts(place_fts, rowid, name) VALUES ('delete', old.id, old.name);
          INSERT INTO place_fts(rowid, name) VALUES (new.id, new.name);
        END;

        CREATE TABLE cell (
          cell TEXT PRIMARY KEY, lat REAL NOT NULL, lon REAL NOT NULL,
          photo_count INTEGER NOT NULL, day_count INTEGER NOT NULL, last_utc INTEGER, near_home INTEGER NOT NULL DEFAULT 0,
          poi_status INTEGER NOT NULL DEFAULT 0,
          attempts INTEGER NOT NULL DEFAULT 0, retry_after INTEGER, fetched_at INTEGER, covered_by TEXT,
          poi_place INTEGER, needs_locality INTEGER NOT NULL DEFAULT 0, apple_locality TEXT, apple_country TEXT
        );
        CREATE INDEX cell_queue ON cell(poi_status, retry_after);

        CREATE TABLE dirty_day (day INTEGER PRIMARY KEY);

        CREATE TABLE poi_cache (cell TEXT PRIMARY KEY, fetched_at INTEGER NOT NULL, status INTEGER NOT NULL,
                                payload BLOB, apple_locality TEXT, apple_country TEXT);
        CREATE TABLE map_search_cache (key TEXT PRIMARY KEY, fetched_at INTEGER NOT NULL, payload BLOB NOT NULL);

        CREATE TABLE saved_place (id INTEGER PRIMARY KEY, name TEXT NOT NULL, name_folded TEXT NOT NULL UNIQUE,
          lat REAL NOT NULL, lon REAL NOT NULL, radius_m REAL NOT NULL, is_home INTEGER NOT NULL DEFAULT 0,
          created_utc INTEGER NOT NULL, updated_utc INTEGER NOT NULL);
        CREATE UNIQUE INDEX saved_place_home ON saved_place(is_home) WHERE is_home = 1;
        CREATE TABLE place_choice (phrase TEXT PRIMARY KEY, place_key TEXT NOT NULL, radius_m REAL, updated_utc INTEGER NOT NULL);
        """

    /// The Vision pass (content search P1a): Vision's photo tags by name, the tags each photo passed with their
    /// confidence and flags (``VisualLabelFlags``; confidences compare only within one tag), and each photo's pass:
    /// its ``VisualStatus``, face and person counts, the largest face's share of the frame, Vision's utility verdict and
    /// aesthetics score, the pass versions and the content edit it read. A photo's rows go with it.
    static let v2Visual = """
        CREATE TABLE visual_label (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);

        CREATE TABLE asset_label (
          label_id   INTEGER NOT NULL REFERENCES visual_label(id),
          asset_id   INTEGER NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
          confidence REAL NOT NULL,
          flags      INTEGER NOT NULL,
          PRIMARY KEY (label_id, asset_id)
        ) WITHOUT ROWID;
        CREATE INDEX asset_label_asset ON asset_label(asset_id);

        CREATE TABLE asset_visual (
          asset_id       INTEGER PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
          status         INTEGER NOT NULL,
          faces          INTEGER, humans INTEGER, largest_face REAL,
          is_utility     INTEGER, aesthetic REAL,
          labels_version INTEGER NOT NULL,
          embed_version  INTEGER,
          adjusted_utc   INTEGER,
          checked_utc    INTEGER NOT NULL
        );
        CREATE INDEX asset_visual_status ON asset_visual(status);
        """

    // MARK: Open

    /// What an existing file holds, before migrating.
    enum State: Equatable {
        /// No tables yet.
        case fresh
        /// Built by this rebuild epoch and only known migrations: migrate.
        case current
        /// Built under another rebuild epoch: rebuild.
        case epochMismatch
        /// Holds migrations this build doesn't know (a downgrade): rebuild.
        case superseded
    }

    static func state(_ db: Database) throws -> State {
        let tables = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master") ?? 0
        if tables == 0 { return .fresh }
        if try Int.fetchOne(db, sql: "PRAGMA user_version") != rebuildEpoch { return .epochMismatch }
        if try migrator.hasBeenSuperseded(db) { return .superseded }
        return .current
    }

    /// Runs the pending migrations and stamps the rebuild epoch.
    static func migrate(_ writer: any DatabaseWriter) throws {
        try migrator.migrate(writer)
        try writer.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = \(rebuildEpoch)") }
    }

    // MARK: User tables across a rebuild

    /// The rows of the user tables, kept in memory while the file is recreated.
    struct UserRows: Sendable {
        var tables: [String: [[String: DatabaseValue]]] = [:]

        var rowCount: Int { tables.values.reduce(0) { $0 + $1.count } }

        /// Reads every user table it can, and the user values in `meta`; a table that can't be read (damaged,
        /// missing) is skipped.
        static func export(_ reader: any DatabaseReader) -> UserRows {
            var rows = UserRows()
            let keys = IndexSchema.userMetaKeys.map { "'\($0.rawValue)'" }.joined(separator: ", ")
            let queries = IndexSchema.userTables.map { ($0, "SELECT * FROM \($0)") } + [("meta", "SELECT * FROM meta WHERE key IN (\(keys))")]
            for (table, sql) in queries {
                let fetched = try? reader.read { db in
                    try Row.fetchAll(db, sql: sql).map { row in
                        Dictionary(row.columnNames.map { ($0, row[$0] as DatabaseValue) }, uniquingKeysWith: { $1 })
                    }
                }
                if let fetched, !(table == "meta" && fetched.isEmpty) { rows.tables[table] = fetched }
            }
            return rows
        }

        /// Inserts the kept rows into the new schema, column by column where the new table still has them, then
        /// mirrors the saved places into `place` again (the structure pass labels moments with them).
        func reimport(_ writer: any DatabaseWriter) throws {
            try writer.write { db in
                for (table, rows) in tables {
                    let columns = Set(try db.columns(in: table).map(\.name))
                    for row in rows {
                        let kept = row.filter { columns.contains($0.key) }.sorted { $0.key < $1.key }
                        guard !kept.isEmpty else { continue }
                        let names = kept.map(\.key).joined(separator: ", ")
                        let marks = Array(repeating: "?", count: kept.count).joined(separator: ", ")
                        try db.execute(sql: "INSERT OR IGNORE INTO \(table) (\(names)) VALUES (\(marks))",
                                       arguments: StatementArguments(kept.map(\.value)))
                    }
                }
                try SavedPlaceRows.mirrorAll(db)
            }
        }
    }
}
