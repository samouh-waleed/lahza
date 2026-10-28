import Foundation
import GRDB
import LZCore
import LZGeo
import LZLibrary
import Synchronization
@testable import LZIndex

/// Shared fixtures: the bundled gazetteer, a fixed clock, asset builders and a canonical dump of the asset
/// table for comparing two indexes.
enum Fixture {
    static let gazetteer: Gazetteer = {
        do { return try Gazetteer.bundled() } catch { fatalError("The bundled gazetteer must load: \(error)") }
    }()

    static let riyadh = TimeZone(identifier: "Asia/Riyadh")!
    /// 2026-10-28T12:00+03:00, the spec's fixed now.
    static let now = Date(timeIntervalSince1970: 1_793_178_000)

    static let nakheel = Coordinate(latitude: 24.7590, longitude: 46.6440)
    static let athens = Coordinate(latitude: 37.9715, longitude: 23.7257)
    static let sydney = Coordinate(latitude: -33.8915, longitude: 151.2767)

    static func indexer(_ database: IndexDatabase, _ reader: any LibraryReader, settings: IndexerSettings = .init(),
                        structure: any StructurePass = DeferredStructurePass(), faults: IndexFaults? = nil,
                        clock: any AppClock = FixedClock(Fixture.now), zone: @escaping @Sendable () -> TimeZone = { Fixture.riyadh }) -> LibraryIndexer {
        LibraryIndexer(database: database, reader: reader, gazetteer: gazetteer, clock: clock, deviceTimeZone: zone,
                       settings: settings, structure: structure, faults: faults)
    }

    /// An indexer with the real structure pass.
    static func structured(_ database: IndexDatabase, _ reader: any LibraryReader, settings: IndexerSettings = .init(),
                           clock: any AppClock = FixedClock(Fixture.now), zone: @escaping @Sendable () -> TimeZone = { Fixture.riyadh }) -> LibraryIndexer {
        indexer(database, reader, settings: settings, structure: LiveStructurePass(), clock: clock, zone: zone)
    }

    /// A place-name queue over `database` that tells `indexer` to restructure.
    static func placeNames(_ database: IndexDatabase, _ indexer: LibraryIndexer, maps: any MapsClient, clock: any AppClock = FixedClock(Fixture.now),
                           budget: MapsBudget? = nil, network: any NetworkStatus = FakeNetworkStatus(reachable: true),
                           policy: PlaceNamePolicy = .default) -> PlaceNameQueue {
        PlaceNameQueue(database: database, maps: maps, budget: budget ?? MapsBudget(perMinute: 60_000, capacity: 10_000, clock: clock), clock: clock,
                       network: network, notify: { await indexer.enqueue(.restructure) }, policy: policy)
    }

    /// The structure an index holds, with place keys instead of row ids: equal for two indexes of the same library
    /// built by different paths.
    static func structure(_ database: IndexDatabase) async throws -> [String] {
        try await database.read { db in
            let assets = try Row.fetchAll(db, sql: """
                SELECT a.local_id, z.name AS zone, a.tz_src, a.wall_s, a.day, a.place_src, a.eff_lat, a.eff_lon, city.key AS city, metro.key AS metro,
                       locality.key AS locality, region.key AS region, country.key AS country, m.day AS m_day, m.start_utc AS m_start, t.start_day AS trip
                FROM asset a LEFT JOIN zone z ON z.id = a.tz LEFT JOIN place city ON city.id = a.city_place LEFT JOIN place metro ON metro.id = a.metro_place
                LEFT JOIN place locality ON locality.id = a.locality_place LEFT JOIN place region ON region.id = a.region_place
                LEFT JOIN place country ON country.id = a.country_place LEFT JOIN moment m ON m.id = a.moment_id LEFT JOIN trip t ON t.id = a.trip_id
                ORDER BY a.local_id
                """).map { "asset \($0)" }
            let moments = try Row.fetchAll(db, sql: """
                SELECT m.day, m.start_utc, m.end_utc, m.start_wall, m.end_wall, z.name AS zone, f.local_id AS first, m.item_count, m.photo_count,
                       m.video_count, m.located_count, m.borrowed_count, m.lat, m.lon, m.spread_m, m.cell, label.key AS label, city.key AS city,
                       country.key AS country, t.start_day AS trip, cover.local_id AS cover
                FROM moment m LEFT JOIN zone z ON z.id = m.tz LEFT JOIN asset f ON f.id = m.first_asset LEFT JOIN place label ON label.id = m.label_place
                LEFT JOIN place city ON city.id = m.city_place LEFT JOIN place country ON country.id = m.country_place
                LEFT JOIN trip t ON t.id = m.trip_id LEFT JOIN asset cover ON cover.id = m.cover_asset ORDER BY m.day, m.start_utc
                """).map { "moment \($0)" }
            let trips = try Row.fetchAll(db, sql: """
                SELECT t.start_day, t.end_day, t.label, label.key AS label_place, country.key AS country, t.abroad, t.moment_count, t.item_count,
                       t.video_count, t.max_km, cover.local_id AS cover
                FROM trip t LEFT JOIN place label ON label.id = t.label_place LEFT JOIN place country ON country.id = t.country_place
                LEFT JOIN asset cover ON cover.id = t.cover_asset ORDER BY t.start_day
                """).map { "trip \($0)" }
            let homes = try Row.fetchAll(db, sql: """
                SELECT h.year, h.lat, h.lon, h.tile, z.name AS zone, h.country_code, h.nights, h.source FROM home_base h LEFT JOIN zone z ON z.id = h.tz ORDER BY h.year
                """).map { "home \($0)" }
            let cells = try Row.fetchAll(db, sql: "SELECT cell, lat, lon, photo_count, day_count, last_utc, near_home, needs_locality, poi_status FROM cell ORDER BY cell")
                .map { "cell \($0)" }
            let places = try Row.fetchAll(db, sql: "SELECT key, kind, name, photo_count, last_utc FROM place WHERE photo_count > 0 ORDER BY key").map { "place \($0)" }
            return assets + moments + trips + homes + cells + places
        }
    }

    /// Runs one job to completion.
    static func sync(_ indexer: LibraryIndexer, _ job: IndexJob = .sync(.launch)) async {
        await indexer.enqueue(job)
        await indexer.settled()
    }

    /// A photo created `utc` seconds after 1970 (nil: undated), optionally located.
    static func photo(_ id: String, _ utc: Int64?, at coordinate: Coordinate? = nil, kind: AssetFacts.Kind = .photo,
                      favorite: Bool = false, width: Int = 4_032) -> LibraryAsset {
        let created = utc.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return LibraryAsset(id: id, facts: AssetFacts(kind: kind, creationDate: created, modificationDate: created,
                                                      addedDate: created.map { $0.addingTimeInterval(3_600) }, coordinate: coordinate,
                                                      horizontalAccuracy: coordinate == nil ? nil : 5, isFavorite: favorite,
                                                      duration: kind == .video ? 12 : 0, pixelWidth: width, pixelHeight: 3_024))
    }

    /// `count` photos an hour apart from 1 Jan 2025, every third one at Al-Nakheel Park.
    static func library(_ count: Int, prefix: String = "a") -> [LibraryAsset] {
        (0..<count).map { index in
            photo("\(prefix)\(String(format: "%05d", index))", 1_735_689_600 + Int64(index) * 3_600, at: index % 3 == 0 ? nakheel : nil)
        }
    }

    /// Every asset row with its zone's name instead of its id, leaving out the row id, the scan generation
    /// and the modification date (which a re-read doesn't refresh): equal for two indexes of the same library.
    static func assetRows(_ database: IndexDatabase) async throws -> [[String: DatabaseValue]] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.local_id, a.kind, a.subtypes, a.flags, a.created_utc, a.added_utc, a.adjusted_utc, a.lat, a.lon, a.h_acc,
                       a.duration, a.width, a.height, a.source, a.meta_fp, z.name AS zone, a.tz_src, a.wall_s, a.day, a.cell,
                       a.place_src, a.eff_lat, a.eff_lon
                FROM asset a LEFT JOIN zone z ON z.id = a.tz ORDER BY a.local_id
                """).map { row in Dictionary(row.columnNames.map { ($0, row[$0] as DatabaseValue) }, uniquingKeysWith: { $1 }) }
        }
    }

    static func localIDs(_ database: IndexDatabase) async throws -> [String] {
        try await database.read { db in try String.fetchAll(db, sql: "SELECT local_id FROM asset ORDER BY local_id") }
    }

    static func dirtyDays(_ database: IndexDatabase) async throws -> Set<Int32> {
        try await database.read { db in Set(try Int32.fetchAll(db, sql: "SELECT day FROM dirty_day")) }
    }

    static func meta(_ database: IndexDatabase) async throws -> SyncState {
        try await database.read { db in try SyncState(db) }
    }

    static func count(_ database: IndexDatabase, _ table: String) async throws -> Int {
        try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    /// A fresh index of `reader`'s library as it is now (the reference for "equals a clean build").
    static func cleanBuild(of reader: FakeLibraryReader, settings: IndexerSettings = .init(), structured: Bool = false,
                           zone: @escaping @Sendable () -> TimeZone = { Fixture.riyadh }) async throws -> IndexDatabase {
        let database = try IndexDatabase.open(.inMemory)
        let visible = try await reader.assets(withIDs: reader.allAssets.map(\.id))
        let snapshot = FakeLibraryReader(.explicit(visible), access: .full)
        await sync(structured ? Fixture.structured(database, snapshot, settings: settings, zone: zone)
                   : indexer(database, snapshot, settings: settings, zone: zone))
        return database
    }

    /// Runs `body` with a new empty folder, removed afterwards.
    static func withTemporaryDirectory<T>(isolation: isolated (any Actor)? = #isolation, _ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lzindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }
}

/// A structure pass that records its calls.
final class RecordingStructurePass: StructurePass {
    struct Call: Sendable, Hashable {
        var daysAfter: Int32?
        var final: Bool
    }

    private let state = Mutex<[Call]>([])
    var calls: [Call] { state.withLock { $0 } }

    func run(_ database: IndexDatabase, _ run: StructureRun) async throws -> Bool {
        state.withLock { $0.append(Call(daysAfter: run.daysAfter, final: run.final)) }
        return false
    }
}

/// Collects a status stream's values in the background.
final class StatusRecorder: Sendable {
    private let state = Mutex<[IndexStatus]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ stream: AsyncStream<IndexStatus>) {
        let listener = Task { [weak self] in
            for await status in stream { self?.state.withLock { $0.append(status) } }
        }
        task.withLock { $0 = listener }
    }

    var values: [IndexStatus] { state.withLock { $0 } }
    var phases: [IndexStatus.Phase] { values.map(\.phase) }

    func cancel() { task.withLock { $0?.cancel() } }
}
